//! The http.zig runtime: the same `App` served by karlseguin/http.zig
//! (epoll/kqueue workers and a thread pool). Import the `kzig_httpz` module,
//! built with `-Dhttpz`.
//!
//! http.zig parses, frames and writes; kzig routes. The handler takes over
//! routing (http.zig's `handle` hook), and the kzig request arena *is*
//! http.zig's `req.arena`, which lives until the response is written — so
//! header values and bodies need no copies.
const std = @import("std");
const builtin = @import("builtin");
const kzig = @import("kzig");
const httpz = @import("httpz");

const Io = std.Io;
const Options = kzig.runtime.Options;

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();

        const Handler = struct {
            server: *Self,

            pub fn handle(h: Handler, req: *httpz.Request, res: *httpz.Response) void {
                h.server.serve(req, res);
            }
        };

        io: Io,
        app: *App,
        options: Options,
        engine: httpz.Server(Handler) = undefined,
        draining: std.atomic.Value(bool) = .init(false),
        /// `engine` holds a pointer to `self`: built on first `run`, once
        /// `self` has its final address.
        gpa: std.mem.Allocator,
        built: bool = false,

        pub fn init(io: Io, gpa: std.mem.Allocator, app: *App, options: Options) !Self {
            var o = options;
            // ponytail: http.zig binds inside listen() and std 0.17 has no
            // getsockname, so port 0 is resolved by binding and closing a
            // throwaway listener — a tiny race, fine for tests.
            if (o.port == 0) o.port = try freePort(io, o.host);
            return .{ .io = io, .gpa = gpa, .app = app, .options = o };
        }

        pub fn deinit(self: *Self) void {
            if (self.built) self.engine.deinit();
        }

        pub fn port(self: *const Self) u16 {
            return self.options.port;
        }

        /// Serves until `shutdown`; requests in flight finish first.
        pub fn run(self: *Self) !void {
            if (!self.built) {
                self.engine = try .init(self.io, self.gpa, config(self.options, self.io), .{ .server = self });
                self.built = true;
            }
            var announce = try self.io.concurrent(announceStarted, .{self});
            defer announce.cancel(self.io) catch {};
            try self.engine.listen();
        }

        /// Stops accepting and tells the app it is draining; responses in
        /// flight carry `connection: close`.
        pub fn shutdown(self: *Self) void {
            if (self.draining.swap(true, .acq_rel)) return;
            if (@hasDecl(App, "beginDrain")) self.app.beginDrain();
            // Before listen() bound, there is nothing to stop yet; `run`
            // then sees `draining` once listening (see announceStarted).
            if (self.built and self.engine._listener != null) self.engine.stop();
        }

        /// `app.started` once http.zig is listening (it binds in listen()).
        fn announceStarted(self: *Self) Io.Cancelable!void {
            while (self.engine._listener == null) try self.io.sleep(.fromMilliseconds(2), .awake);
            if (self.draining.load(.acquire)) {
                self.engine.stop();
                return;
            }
            if (@hasDecl(App, "started")) self.app.started(.{ .port = self.options.port });
        }

        fn serve(self: *Self, req: *httpz.Request, res: *httpz.Response) void {
            const arena = req.arena;
            const method = methodOf(req) orelse return notImplemented(res);
            const headers = arena.alloc(kzig.Header, req.headers.len) catch return internalError(res);
            for (req.headers.keys[0..req.headers.len], req.headers.values[0..req.headers.len], headers) |k, v, *h|
                h.* = .{ .name = k, .value = v };

            const request: kzig.Request = .{
                .method = method,
                .path = req.url.path,
                .query = req.url.query,
                .headers = headers,
                .body = req.body() orelse "",
            };
            var response: kzig.Response = .{};
            var ctx: kzig.Ctx = .{ .arena = arena, .req = &request, .res = &response };
            self.app.handle(&ctx);

            const w = kzig.runtime.wire.finish(method, request.path, &response);
            res.status = @backingInt(w.status);
            for (response.headers.items) |h| if (kzig.runtime.wire.sendable(h)) res.header(h.name, h.value);
            res.body = w.body;
            if (self.draining.load(.acquire)) res.keepalive = false;
        }
    };
}

/// Runs `app` on http.zig until SIGINT or SIGTERM, then drains, as
/// `kzig.runtime.std.serve` does.
pub fn serve(comptime App: type, app: *App, io: Io, gpa: std.mem.Allocator, options: Options) !void {
    var server: Server(App) = try .init(io, gpa, app, options);
    defer server.deinit();
    kzig.runtime.signals.install();
    if (!builtin.is_test) std.log.info("listening on http://{s}:{d} (http.zig)", .{ options.host, server.port() });
    var fut = try io.concurrent(runErased(App), .{&server});
    while (kzig.runtime.signals.count() == 0) io.sleep(.fromMilliseconds(100), .awake) catch break;
    if (!builtin.is_test) std.log.info("shutting down: draining connections", .{});
    server.shutdown();
    try fut.await(io);
}

fn runErased(comptime App: type) fn (*Server(App)) anyerror!void {
    return struct {
        fn f(s: *Server(App)) anyerror!void {
            return s.run();
        }
    }.f;
}

fn config(o: Options, io: Io) httpz.Config {
    _ = io;
    const ip = Io.net.IpAddress.parse(o.host, o.port) catch Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = o.port } };
    return .{
        .address = .{ .ip = ip },
        .workers = .{ .max_conn = @intCast(@min(o.max_connections, std.math.maxInt(u16))) },
        .request = .{
            .max_body_size = o.max_body_bytes,
            .buffer_size = o.max_header_bytes,
            // http.zig drops headers past its default of 32 silently.
            .max_header_count = 100,
        },
        .response = .{ .max_header_count = 64 },
        .timeout = .{
            .keepalive = seconds(o.head_timeout_ms),
            .request = seconds(o.body_timeout_ms),
        },
    };
}

/// http.zig's timeouts are whole seconds; 0 disables.
fn seconds(ms: u32) ?u32 {
    return if (ms == 0) null else std.math.divCeil(u32, ms, 1000) catch unreachable;
}

fn methodOf(req: *const httpz.Request) ?std.http.Method {
    return switch (req.method) {
        .GET => .GET,
        .HEAD => .HEAD,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        .CONNECT => .CONNECT,
        .OTHER => std.meta.stringToEnum(std.http.Method, req.method_string),
    };
}

fn notImplemented(res: *httpz.Response) void {
    res.status = 501;
    res.header("content-type", "application/problem+json");
    res.body = "{\"type\":\"about:blank\",\"title\":\"Not Implemented\",\"status\":501}";
}

fn internalError(res: *httpz.Response) void {
    res.status = 500;
    res.header("content-type", "application/json");
    res.body = "{\"message\":\"Internal Server Error\"}";
}

fn freePort(io: Io, host: []const u8) !u16 {
    const address = try Io.net.IpAddress.parse(host, 0);
    var probe = try address.listen(io, .{ .reuse_address = true });
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

test "httpz runtime conformance" {
    try kzig.runtime.conformance.run(Server, .{
        .differences = &.{
            // http.zig writes the 431 itself and closes with the head unread:
            // the kernel's reset can destroy the response before the client
            // reads it.
            "oversized head is 431",
        },
    });
}
