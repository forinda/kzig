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
const websocket = httpz.websocket;

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();

        const Handler = struct {
            server: *Self,

            pub const WebsocketHandler = if (wsEnabled(App)) WsHandler else httpz.DummyWebsocketHandler;

            pub fn handle(h: Handler, req: *httpz.Request, res: *httpz.Response) void {
                h.server.serve(req, res);
            }
        };

        /// http.zig frames and answers pings and closes; kzig gets messages.
        const WsHandler = struct {
            server: *Self,
            conn: *websocket.Conn,
            gateway: usize,
            upgrade: ws.Upgrade,
            session: ?*ws.Session = null,

            const Init = struct { server: *Self, gateway: usize, upgrade: ws.Upgrade };

            pub fn init(conn: *websocket.Conn, ctx: *const Init) !WsHandler {
                return .{ .server = ctx.server, .conn = conn, .gateway = ctx.gateway, .upgrade = ctx.upgrade };
            }

            /// After the handshake: the gateway's `connect` may send, or close.
            pub fn afterInit(self: *WsHandler) !void {
                self.session = try self.server.app.wsOpen(self.gateway, .{ .ptr = self.conn, .vtable = &conn_vtable }, self.upgrade);
            }

            pub fn clientMessage(self: *WsHandler, data: []const u8, kind: enum { text, binary }) !void {
                const s = self.session orelse return;
                if (kind == .binary) return s.close(1003, "Binary frames are not supported");
                // http.zig's own cap is twice this and drops the socket silently.
                if (data.len > App.ws_max_payload) return s.close(1009, "");
                if (s.closed.load(.acquire)) return;
                self.server.app.wsMessage(s, data);
            }

            pub fn clientPong(self: *WsHandler, _: []const u8) !void {
                if (self.session) |s| self.server.app.wsPong(s);
            }

            pub fn close(self: *WsHandler) void {
                const s = self.session orelse return;
                self.session = null;
                self.server.app.wsClose(s);
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

        pub fn init(io: Io, gpa: std.mem.Allocator, app: *App, options: Options) !Self {
            var o = options;
            // ponytail: http.zig binds inside listen() and std 0.17 has no
            // getsockname, so port 0 is resolved by binding and closing a
            // throwaway listener — a tiny race, fine for tests.
            if (o.port == 0) o.port = try freePort(io, o.host);
            return .{ .io = io, .gpa = gpa, .app = app, .options = o };
        }

        pub fn deinit(self: *Self) void {
            if (self.built.load(.acquire)) self.engine.deinit();
        }

        pub fn port(self: *const Self) u16 {
            return self.options.port;
        }

        /// Serves until `shutdown`; requests in flight finish first.
        pub fn run(self: *Self) !void {
            if (!self.built.load(.acquire)) {
                var cfg = config(self.options, self.io);
                if (comptime wsEnabled(App)) cfg.websocket = .{ .max_message_size = App.ws_max_payload * 2 };
                self.engine = try .init(self.io, self.gpa, cfg, .{ .server = self });
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
            const headers = req.arena.alloc(kzig.Header, req.headers.len) catch return internalError(res);
            for (req.headers.keys[0..req.headers.len], req.headers.values[0..req.headers.len], headers) |k, v, *h|
                h.* = .{ .name = k, .value = v };
            const init_ctx: WsHandler.Init = .{ .server = self, .gateway = gateway, .upgrade = .{ .path = req.url.path, .query = req.url.query, .headers = headers } };
            if (httpz.upgradeWebsocket(WsHandler, req, res, &init_ctx) catch false) return;
            // No key, or not version 13.
            res.status = 400;
            res.header("content-type", "application/problem+json");
            res.body = "{\"type\":\"about:blank\",\"title\":\"Bad Request\",\"status\":400}";
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

const conn_vtable: ws.Conn.VTable = .{ .send = wsSend, .ping = wsPing, .close = wsClose };

fn wsSend(ptr: *anyopaque, data: []const u8) anyerror!void {
    const c: *websocket.Conn = @ptrCast(@alignCast(ptr));
    try c.writeText(data);
}

fn wsPing(ptr: *anyopaque) anyerror!void {
    const c: *websocket.Conn = @ptrCast(@alignCast(ptr));
    var empty: [0]u8 = .{};
    try c.writePing(&empty);
}

/// A close frame, then no more sending (code 0: drop the socket). The
/// socket itself stays http.zig's to close, when the client hangs up.
fn wsClose(ptr: *anyopaque, code: u16, reason: []const u8) void {
    const c: *websocket.Conn = @ptrCast(@alignCast(ptr));
    // http.zig closes a socket before telling the handler; until then a
    // broadcast can reach a closed one, which websocket.zig's writes report
    // as an error.
    if (c.isClosed()) return;
    if (code != 0) {
        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        const n = @min(reason.len, payload.len - 2);
        @memcpy(payload[2..][0..n], reason[0..n]);
        c.writeFrame(.close, payload[0 .. 2 + n]) catch {};
    }
    // ponytail: the raw call, as `Io` panics on a closed descriptor; the
    // descriptor closing (and being reused) between the check above and here
    // is the race websocket.zig's own writes accept.
    _ = std.posix.system.shutdown(c.stream.socket.handle, if (code == 0) std.posix.SHUT.RDWR else std.posix.SHUT.WR);
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
