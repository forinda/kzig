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
const ws = kzig.ws;
const ws_serve = kzig.ws_serve;

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();

        const Handler = struct {
            server: *Self,

            pub fn handle(h: Handler, req: *httpz.Request, res: *httpz.Response) void {
                h.server.serve(req, res);
            }
        };

        /// A WebSocket after the 101: the socket is disowned from http.zig
        /// and served like the std runtime's, closed only after the App let go.
        const WsJob = struct {
            server: *Self,
            arena: std.heap.ArenaAllocator,
            gateway: usize,
            upgrade: ws.Upgrade,
            stream: Io.net.Stream,
            rbuf: [8192]u8 = undefined,
            wbuf: [8192]u8 = undefined,

            fn run(job: *WsJob) void {
                const srv = job.server;
                defer {
                    job.stream.close(srv.io);
                    job.arena.deinit();
                    srv.gpa.destroy(job);
                }
                var sr = job.stream.reader(srv.io, &job.rbuf);
                var sw = job.stream.writer(srv.io, &job.wbuf);
                ws_serve.serve(App, srv.app, srv.io, srv.gpa, job.stream, &sr.interface, &sw.interface, job.gateway, job.upgrade);
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
        built: std.atomic.Value(bool) = .init(false),
        /// WebSocket connections, which outlive their request.
        ws_group: Io.Group = .init,

        pub fn init(io: Io, gpa: std.mem.Allocator, app: *App, options: Options) !Self {
            var o = options;
            // ponytail: http.zig binds inside listen() and std 0.17 has no
            // getsockname, so port 0 is resolved by binding and closing a
            // throwaway listener — a tiny race, fine for tests.
            if (o.port == 0) o.port = try freePort(io, o.host);
            return .{ .io = io, .gpa = gpa, .app = app, .options = o };
        }

        pub fn deinit(self: *Self) void {
            // Drain closed them; this ends any still open.
            self.ws_group.cancel(self.io);
            if (self.built.load(.acquire)) self.engine.deinit();
        }

        pub fn port(self: *const Self) u16 {
            return self.options.port;
        }

        /// Serves until `shutdown`; requests in flight finish first.
        pub fn run(self: *Self) !void {
            if (!self.built.load(.acquire)) {
                self.engine = try .init(self.io, self.gpa, config(self.options, self.io), .{ .server = self });
                self.built.store(true, .release);
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
            if (self.built.load(.acquire) and self.listening()) self.engine.stop();
        }

        /// `app.started` once http.zig is listening (it binds in listen()).
        fn announceStarted(self: *Self) Io.Cancelable!void {
            while (!self.listening()) try self.io.sleep(.fromMilliseconds(2), .awake);
            if (self.draining.load(.acquire)) {
                self.engine.stop();
                return;
            }
            if (@hasDecl(App, "started")) self.app.started(.{ .port = self.options.port });
        }

        /// http.zig sets `_listener` under its mutex once bound.
        fn listening(self: *Self) bool {
            self.engine._mut.lockUncancelable(self.io);
            defer self.engine._mut.unlock(self.io);
            return self.engine._listener != null;
        }

        fn upgradeTo(self: *Self, req: *httpz.Request, res: *httpz.Response, gateway: usize) void {
            const key = req.header("sec-websocket-key");
            if (ws_serve.check(key, req.header("sec-websocket-version"))) |refusal| {
                res.header("content-type", "application/problem+json");
                switch (refusal) {
                    .bad_request => {
                        res.status = 400;
                        res.body = "{\"type\":\"about:blank\",\"title\":\"Bad Request\",\"status\":400}";
                    },
                    .upgrade_required => {
                        res.status = 426;
                        res.header("sec-websocket-version", "13");
                        res.body = "{\"type\":\"about:blank\",\"title\":\"Upgrade Required\",\"status\":426}";
                    },
                }
                return;
            }
            const job = self.gpa.create(WsJob) catch return internalError(res);
            job.* = .{ .server = self, .arena = .init(self.gpa), .gateway = gateway, .upgrade = undefined, .stream = res.conn.stream };
            // The request's memory goes back to http.zig when this returns.
            job.upgrade = copyUpgrade(job.arena.allocator(), req) catch {
                job.arena.deinit();
                self.gpa.destroy(job);
                return internalError(res);
            };
            res.conn.blockingMode() catch {};
            res.disown() catch {};
            var buf: [256]u8 = undefined;
            var w = job.stream.writer(self.io, &buf);
            w.interface.print("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: upgrade\r\nsec-websocket-accept: {s}\r\n\r\n", .{&ws_serve.acceptKey(key.?)}) catch {};
            w.interface.flush() catch {};
            self.ws_group.concurrent(self.io, WsJob.run, .{job}) catch {
                job.stream.close(self.io);
                job.arena.deinit();
                self.gpa.destroy(job);
            };
        }

        fn copyUpgrade(a: std.mem.Allocator, req: *httpz.Request) !ws.Upgrade {
            const headers = try a.alloc(kzig.Header, req.headers.len);
            for (req.headers.keys[0..req.headers.len], req.headers.values[0..req.headers.len], headers) |k, v, *h|
                h.* = .{ .name = try a.dupe(u8, k), .value = try a.dupe(u8, v) };
            return .{ .path = try a.dupe(u8, req.url.path), .query = try a.dupe(u8, req.url.query), .headers = headers };
        }

        fn serve(self: *Self, req: *httpz.Request, res: *httpz.Response) void {
            const arena = req.arena;
            if (comptime wsEnabled(App)) if (req.header("upgrade")) |upgrade| if (std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
                if (self.app.wsRoute(req.url.path)) |gateway| return self.upgradeTo(req, res, gateway);
            };
            // http.zig drops headers past its count before framing the body:
            // a content-length after them would be lost and the body read as
            // the next request. Refuse and close instead.
            if (req.headers.len == max_request_headers) {
                req.conn.handover = .close;
                res.status = 431;
                res.header("content-type", "application/problem+json");
                res.body = "{\"type\":\"about:blank\",\"title\":\"Request Header Fields Too Large\",\"status\":431}";
                return;
            }
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
            // http.zig writes what it's given; it declares a set Content-Length as is.
            if (method == .HEAD and w.length > 0)
                res.header("Content-Length", std.fmt.allocPrint(arena, "{d}", .{w.length}) catch return internalError(res));
            if (self.draining.load(.acquire)) req.conn.handover = .close;
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
    var stopped: std.atomic.Value(bool) = .init(false);
    var fut = try io.concurrent(runErased(App), .{ &server, &stopped });
    while (kzig.runtime.signals.count() == 0 and !stopped.load(.acquire)) io.sleep(.fromMilliseconds(100), .awake) catch break;
    // run ended on its own (a bind error, say): report it.
    if (stopped.load(.acquire)) return fut.await(io);
    if (!builtin.is_test) std.log.info("shutting down: draining connections", .{});
    server.shutdown();
    try fut.await(io);
}

fn runErased(comptime App: type) fn (*Server(App), *std.atomic.Value(bool)) anyerror!void {
    return struct {
        fn f(s: *Server(App), stopped: *std.atomic.Value(bool)) anyerror!void {
            defer stopped.store(true, .release);
            return s.run();
        }
    }.f;
}

const max_request_headers = 100;

fn wsEnabled(comptime App: type) bool {
    return @hasDecl(App, "ws_paths") and App.ws_paths.len > 0;
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
            .max_header_count = max_request_headers,
        },
        .response = .{ .max_header_count = 64 },
        .timeout = .{
            // http.zig's `request` runs from the first byte to the end of the
            // body, `keepalive` between requests: the tighter of our two
            // budgets bounds a slow head.
            .keepalive = seconds(o.head_timeout_ms),
            .request = seconds(if (o.head_timeout_ms == 0) o.body_timeout_ms else if (o.body_timeout_ms == 0) o.head_timeout_ms else @min(o.head_timeout_ms, o.body_timeout_ms)),
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
            // http.zig sends the response but keeps a reused connection open
            // after `connection: close`; a client waiting for EOF hangs.
            "connection: close is honoured on a reused connection",
        },
    });
}
