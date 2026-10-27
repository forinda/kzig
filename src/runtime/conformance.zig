//! The behaviour every runtime must share, checked over a real socket.
//! `run(Server)` takes a runtime's `Server(App)` function; each runtime's
//! tests call it. Engine-specific behaviour (timeouts, signals) is tested
//! next to the engine.
const std = @import("std");
const context = @import("../context.zig");
const router = @import("../router.zig");
const adapter = @import("../adapter.zig");
const Options = @import("options.zig").Options;
const app_mod = @import("../app.zig");
const ws = @import("../ws.zig");
const WsClient = @import("../testing.zig").WsClient;

const Io = std.Io;
const Ctx = context.Ctx;
const testing = std.testing;

pub const App = struct {
    port: u16 = 0,
    drained: bool = false,

    const R = router.Router(&.{
        router.route(.GET, "/hello", struct {
            fn f(_: *Ctx) []const u8 {
                return "hi";
            }
        }.f),
        router.route(.GET, "/secret", struct {
            fn f(_: *Ctx) []const u8 {
                return "SECRET";
            }
        }.f),
        router.route(.POST, "/echo", struct {
            fn f(ctx: *Ctx) []const u8 {
                return ctx.req.body;
            }
        }.f),
        router.route(.DELETE, "/echo", struct {
            fn f(ctx: *Ctx) []const u8 {
                return ctx.req.body;
            }
        }.f),
        router.route(.GET, "/empty", struct {
            fn f(ctx: *Ctx) !void {
                ctx.status(.no_content);
                try ctx.text("body");
            }
        }.f),
        router.route(.GET, "/framed", struct {
            fn f(ctx: *Ctx) ![]const u8 {
                try ctx.setHeader("content-length", "999");
                try ctx.setHeader("transfer-encoding", "chunked");
                return "hi";
            }
        }.f),
        router.route(.GET, "/slow", struct {
            fn f(_: *Ctx) ![]const u8 {
                try testing.io.sleep(.fromMilliseconds(200), .awake);
                return "done";
            }
        }.f),
    });

    pub fn handle(_: *App, ctx: *Ctx) void {
        (R{}).handle(ctx);
    }
    pub fn started(self: *App, info: adapter.StartInfo) void {
        self.port = info.port;
    }
    pub fn beginDrain(self: *App) void {
        self.drained = true;
    }
};

fn Harness(comptime ServerFn: fn (type) type) type {
    const S = ServerFn(App);
    return struct {
        const Self = @This();
        app: App = .{},
        srv: S = undefined,
        fut: Io.Future(anyerror!void) = undefined,

        fn start(self: *Self, opts: Options) !void {
            var o = opts;
            o.port = 0;
            self.srv = try .init(testing.io, testing.allocator, &self.app, o);
            self.fut = try testing.io.concurrent(runErased, .{&self.srv});
        }
        fn runErased(srv: *S) anyerror!void {
            return srv.run();
        }
        fn stop(self: *Self) void {
            self.srv.shutdown();
            self.fut.cancel(testing.io) catch {};
            self.srv.deinit();
        }
        fn connect(self: *Self) !Io.net.Stream {
            const addr = try Io.net.IpAddress.parse("127.0.0.1", self.srv.port());
            // http.zig binds in run(); wait for the listener.
            var tries: usize = 0;
            while (true) : (tries += 1) {
                return addr.connect(testing.io, .{ .mode = .stream }) catch |err| {
                    if (tries > 200) return err;
                    try testing.io.sleep(.fromMilliseconds(5), .awake);
                    continue;
                };
            }
        }
        /// Sends the check's requests, returns everything the server wrote
        /// until it closed — or until `deadline_ms`, when the client gives up
        /// (a server that never closes fails a check instead of hanging it).
        fn exchange(self: *Self, c: Check, elapsed_ms: *i64) ![]u8 {
            const s = try self.connect();
            defer s.close(testing.io);
            var guard = try testing.io.concurrent(giveUp, .{ s, deadline_ms });
            defer guard.cancel(testing.io) catch {};
            var rbuf: [4096]u8 = undefined;
            var r = s.reader(testing.io, &rbuf);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(testing.allocator);
            const t0 = Io.Clock.awake.now(testing.io);
            try send(s, c.request);
            if (c.later) |more| {
                try testing.io.sleep(.fromMilliseconds(50), .awake);
                // The server may already have answered and closed.
                send(s, more) catch {};
            }
            if (c.then) |next| {
                try readResponse(&r.interface, &out);
                try send(s, next);
            }
            if (c.half_close) s.shutdown(testing.io, .send) catch {};
            r.interface.appendRemaining(testing.allocator, &out, .limited(64 * 1024)) catch |err| switch (err) {
                // The guard shut the socket: report what arrived.
                error.ReadFailed => {},
                else => return err,
            };
            elapsed_ms.* = @intCast(@divTrunc(t0.durationTo(Io.Clock.awake.now(testing.io)).toNanoseconds(), std.time.ns_per_ms));
            return out.toOwnedSlice(testing.allocator);
        }
    };
}

const deadline_ms = 3000;

fn giveUp(s: Io.net.Stream, ms: i64) Io.Cancelable!void {
    try testing.io.sleep(.fromMilliseconds(ms), .awake);
    s.shutdown(testing.io, .both) catch {};
}

fn send(stream: Io.net.Stream, raw: []const u8) !void {
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(testing.io, &wbuf);
    try w.interface.writeAll(raw);
    try w.interface.flush();
}

fn readAll(stream: Io.net.Stream) ![]u8 {
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(testing.io, &rbuf);
    return r.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
}

/// One response: head lines, then `content-length` bytes of body.
fn readResponse(r: *Io.Reader, out: *std.ArrayList(u8)) !void {
    var length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        try out.appendSlice(testing.allocator, line);
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:"))
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " "), 10);
    }
    try out.appendSlice(testing.allocator, try r.take(length));
}

fn fill(comptime n: usize, comptime c: u8) [n]u8 {
    return @splat(c);
}

fn manyHeaders(comptime n: usize) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (0..n) |i| out = out ++ std.fmt.comptimePrint("x-h{d}: v\r\n", .{i});
        const result = out;
        return result;
    }
}

fn has(out: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, out, needle) != null;
}

const Check = struct {
    name: []const u8,
    opts: Options = .{},
    request: []const u8,
    /// Sent on the same connection after the first response was read
    /// (keep-alive as clients use it; pipelining is engine-specific).
    then: ?[]const u8 = null,
    /// Sent 50 ms after `request`, without reading: a second packet.
    later: ?[]const u8 = null,
    /// The server must have closed the connection within this time.
    close_within_ms: ?i64 = null,
    half_close: bool = false,
    expect: *const fn (out: []const u8) bool,
};

const smuggled = "GET /secret HTTP/1.1\r\nhost: x\r\n\r\n";

const checks = [_]Check{
    .{ .name = "serves a route", .request = "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 200 ") and std.mem.endsWith(u8, o, "\r\n\r\nhi");
        }
    }.f },
    .{ .name = "keep-alive serves two requests", .request = "GET /hello HTTP/1.1\r\nhost: x\r\n\r\n", .then = "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.count(u8, o, " 200 ") == 2;
        }
    }.f },
    .{ .name = "request body reaches the handler", .request = "POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 5\r\nconnection: close\r\n\r\nhello", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.endsWith(u8, o, "\r\n\r\nhello");
        }
    }.f },
    .{ .name = "DELETE body reaches the handler", .request = "DELETE /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.endsWith(u8, o, "\r\n\r\nok");
        }
    }.f },
    .{ .name = "content-length over limit is 413", .opts = .{ .max_body_bytes = 16 }, .request = "POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 100\r\n\r\n" ++ fill(100, 'a'), .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 413 ");
        }
    }.f },
    .{ .name = "oversized head is 431", .opts = .{ .max_header_bytes = 1024 }, .request = "GET /hello HTTP/1.1\r\nx-big: " ++ fill(2000, 'a') ++ "\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 431 ");
        }
    }.f },
    .{ .name = "POST without content-length has an empty body", .request = "POST /echo HTTP/1.1\r\nhost: x\r\n\r\n", .then = "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            var lower: [1024]u8 = undefined;
            if (o.len > lower.len) return false;
            const l = std.ascii.lowerString(&lower, o);
            return std.mem.count(u8, o, "HTTP/1.1 ") == 2 and std.mem.startsWith(u8, o, "HTTP/1.1 200 ") and
                std.mem.find(u8, l, "content-length: 0\r\n") != null;
        }
    }.f },
    .{ .name = "a body on GET is not parsed as the next request", .half_close = true, .request = std.fmt.comptimePrint("GET /hello HTTP/1.1\r\nhost: x\r\ncontent-length: {d}\r\n\r\n", .{smuggled.len}), .later = smuggled, .expect = struct {
        fn f(o: []const u8) bool {
            return !has(o, "SECRET");
        }
    }.f },
    .{ .name = "framing after 100 headers is not lost (no smuggling)", .half_close = true, .request = "POST /echo HTTP/1.1\r\nhost: x\r\n" ++ manyHeaders(150) ++
        std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{smuggled.len}), .later = smuggled, .expect = struct {
        fn f(o: []const u8) bool {
            return !has(o, "SECRET");
        }
    }.f },
    .{ .name = "connection: close is honoured on a reused connection", .request = "GET /hello HTTP/1.1\r\nhost: x\r\n\r\n", .then = "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .close_within_ms = 1000, .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.count(u8, o, " 200 ") == 2;
        }
    }.f },
    .{ .name = "a partial head is cut at head_timeout_ms", .opts = .{ .head_timeout_ms = 1000, .body_timeout_ms = 30_000 }, .request = "GET /hello HTTP/1.1\r\nhost: x\r\n", .close_within_ms = 2500, .expect = struct {
        fn f(_: []const u8) bool {
            return true;
        }
    }.f },
    .{ .name = "content-length with transfer-encoding is refused", .half_close = true, .request = "POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 4\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n" ++ smuggled, .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 400 ") and !has(o, "SECRET");
        }
    }.f },
    .{ .name = "204 is sent without a body", .request = "GET /empty HTTP/1.1\r\nhost: x\r\n\r\n", .then = "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 204 ") and !has(o, "body") and std.mem.count(u8, o, "HTTP/1.1 ") == 2;
        }
    }.f },
    .{ .name = "HEAD is answered without a body", .request = "HEAD /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            return std.mem.startsWith(u8, o, "HTTP/1.1 200 ") and std.mem.endsWith(u8, o, "\r\n\r\n");
        }
    }.f },
    .{ .name = "framing headers from a handler are not sent", .request = "GET /framed HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", .expect = struct {
        fn f(o: []const u8) bool {
            var lower: [512]u8 = undefined;
            if (o.len > lower.len) return false;
            const l = std.ascii.lowerString(&lower, o);
            return std.mem.find(u8, l, "transfer-encoding") == null and
                std.mem.count(u8, l, "content-length") == 1 and std.mem.find(u8, l, "content-length: 2\r\n") != null;
        }
    }.f },
};

pub const Known = struct {
    /// Checks this engine is known to fail, by name; each must be listed
    /// as a follow-up in ROADMAP.md.
    differences: []const []const u8 = &.{},
};

/// Runs every check against `ServerFn` (a runtime's `Server`), naming the
/// first that fails. A known difference that starts passing fails too, so
/// the list stays true.
pub fn run(comptime ServerFn: fn (type) type, comptime known: Known) !void {
    const H = Harness(ServerFn);
    var failed: usize = 0;
    inline for (checks) |c| {
        const expected_to_fail = comptime for (known.differences) |d| {
            if (std.mem.eql(u8, d, c.name)) break true;
        } else false;
        var h: H = .{};
        try h.start(c.opts);
        var ms: i64 = 0;
        const result = h.exchange(c, &ms);
        h.stop();
        const ok = if (result) |out| blk: {
            defer testing.allocator.free(out);
            const pass = c.expect(out) and (c.close_within_ms == null or ms <= c.close_within_ms.?);
            if (!pass and !expected_to_fail) std.debug.print("conformance: {s} failed after {d} ms; the server wrote:\n{s}\n", .{ c.name, ms, out });
            break :blk pass;
        } else |err| blk: {
            if (!expected_to_fail) std.debug.print("conformance: {s}: {t}\n", .{ c.name, err });
            break :blk false;
        };
        if (expected_to_fail and ok) {
            std.debug.print("conformance: {s} now passes; drop it from the known differences\n", .{c.name});
            failed += 1;
        } else if (!expected_to_fail and !ok) failed += 1;
    }
    try lifecycle(ServerFn);
    try webSockets(ServerFn);
    if (failed > 0) return error.ConformanceFailed;
}

fn lifecycle(comptime ServerFn: fn (type) type) !void {
    const H = Harness(ServerFn);
    {
        // started gets the port; shutdown lets an in-flight request finish.
        var h: H = .{};
        try h.start(.{});
        const s = try h.connect();
        defer s.close(testing.io);
        try send(s, "GET /slow HTTP/1.1\r\nhost: x\r\n\r\n");
        try testing.io.sleep(.fromMilliseconds(50), .awake);
        const port = h.srv.port();
        h.srv.shutdown();
        const out = try readAll(s);
        defer testing.allocator.free(out);
        h.fut.cancel(testing.io) catch {};
        h.srv.deinit();
        if (h.app.port != port) return fail("started gets the port", out);
        if (!h.app.drained) return fail("shutdown tells the app it is draining", out);
        if (!std.mem.endsWith(u8, out, "\r\n\r\ndone")) return fail("shutdown lets an in-flight request finish", out);

        const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
        if (addr.connect(testing.io, .{ .mode = .stream })) |late| {
            late.close(testing.io);
            return fail("new connections are refused after shutdown", "");
        } else |_| {}
    }
}

fn fail(name: []const u8, out: []const u8) error{ConformanceFailed} {
    std.debug.print("conformance: {s} failed; the server wrote:\n{s}\n", .{ name, out });
    return error.ConformanceFailed;
}

/// A gateway exercising what every runtime must do with a WebSocket.
const Echo = struct {
    pub const path = "/echo";
    pub const State = struct { name: []const u8 = "" };
    const WsCtx = ws.Ctx(State);
    pub const events = .{
        .{ .event = "join", .handler = "join" },
        .{ .event = "say", .handler = "say" },
        .{ .event = "*", .handler = "unknown" },
    };

    pub fn connect(_: *Echo, ctx: *WsCtx) !void {
        const name = try ctx.query("name") orelse return ctx.close(4401, "Unauthorized");
        ctx.state.name = try ctx.conn_arena.dupe(u8, name);
        try ctx.send("welcome", .{ .name = name });
    }

    pub fn join(_: *Echo, ctx: *WsCtx, data: struct { room: []const u8 }) !void {
        try ctx.join(data.room);
        try ctx.to(data.room).send("joined", .{ .room = data.room, .name = ctx.state.name });
    }

    pub fn say(_: *Echo, ctx: *WsCtx, data: struct { room: []const u8, text: []const u8 }) !void {
        if (!ctx.inRoom(data.room)) return ctx.send("error", .{ .message = "join first" });
        try ctx.to(data.room).send("said", .{ .from = ctx.state.name, .text = data.text });
    }

    pub fn unknown(_: *Echo, ctx: *WsCtx, _: std.json.Value) !void {
        try ctx.send("error", .{ .message = try std.fmt.allocPrint(ctx.arena, "unknown event: {s}", .{ctx.event}) });
    }

    pub fn draining(_: *Echo, ctx: *WsCtx) !void {
        try ctx.send("server:draining", .{});
    }
};

pub const WsApp = app_mod.App(.{
    .modules = &.{app_mod.Module(.{ .name = "Chat", .gateways = &.{Echo} })},
    .ws = .{ .heartbeat_ms = 150, .max_payload = 1024 },
});

fn WsHarness(comptime ServerFn: fn (type) type) type {
    const S = ServerFn(WsApp);
    return struct {
        const Self = @This();
        app: WsApp = undefined,
        srv: S = undefined,
        fut: Io.Future(anyerror!void) = undefined,

        fn start(self: *Self) !void {
            var env: std.process.Environ.Map = .init(testing.allocator);
            defer env.deinit();
            try env.put("NODE_ENV", "test");
            try self.app.init(testing.io, testing.allocator, &env);
            self.srv = try .init(testing.io, testing.allocator, &self.app, .{ .port = 0 });
            self.fut = try testing.io.concurrent(runErased, .{&self.srv});
        }
        fn runErased(srv: *S) anyerror!void {
            return srv.run();
        }
        fn stop(self: *Self) void {
            self.srv.shutdown();
            self.fut.cancel(testing.io) catch {};
            self.srv.deinit();
            self.app.deinit();
        }
        fn client(self: *Self, target: []const u8) !*WsClient {
            return WsClient.connect(testing.allocator, testing.io, self.srv.port(), target);
        }
    };
}

fn webSockets(comptime ServerFn: fn (type) type) !void {
    const H = WsHarness(ServerFn);
    {
        var h: H = .{};
        try h.start();
        defer h.stop();
        const a = try h.client("/ws/echo?name=ann");
        defer a.deinit();
        if (a.status != 101) return fail("ws: an upgrade to a gateway answers 101", "");
        if (!has(try a.expect("welcome"), "\"name\":\"ann\"")) return fail("ws: connect runs and can send", "");
        const nope = try h.client("/ws/nope");
        defer nope.deinit();
        if (nope.status != 404) return fail("ws: an upgrade to no gateway is 404", "");
        const anon = try h.client("/ws/echo");
        defer anon.deinit();
        if (try anon.closeCode() != 4401) return fail("ws: connect can close the socket (4401)", "");
    }
    {
        var h: H = .{};
        try h.start();
        defer h.stop();
        const a = try h.client("/ws/echo?name=ann");
        defer a.deinit();
        const b = try h.client("/ws/echo?name=ben");
        defer b.deinit();
        const c = try h.client("/ws/echo?name=cy");
        defer c.deinit();
        try a.emit("join", .{ .room = "red" });
        _ = try a.expect("joined");
        try b.emit("join", .{ .room = "red" });
        if (!has(try a.expect("joined"), "ben")) return fail("ws: a room hears who joins", "");
        try c.emit("join", .{ .room = "blue" });
        _ = try c.expect("joined");
        try a.emit("say", .{ .room = "red", .text = "hi" });
        if (!has(try b.expect("said"), "\"text\":\"hi\"")) return fail("ws: a room message reaches the room", "");
        if (!has(try a.expect("said"), "\"from\":\"ann\"")) return fail("ws: a room message reaches the sender", "");
        try c.emit("say", .{ .room = "red", .text = "sneaky" });
        if (!has(try c.expect("error"), "join first")) return fail("ws: inRoom", "");
        // c is in blue only: its next frame must not be red's.
        try c.emit("say", .{ .room = "blue", .text = "own" });
        if (!has(try c.expect("said"), "own")) return fail("ws: rooms are isolated", "");
    }
    {
        var h: H = .{};
        try h.start();
        defer h.stop();
        const a = try h.client("/ws/echo?name=ann");
        defer a.deinit();
        try a.send("not json");
        if (!has(try a.expect("error"), "Invalid JSON")) return fail("ws: bad JSON is an error event", "");
        try a.send("{\"data\":1}");
        if (!has(try a.expect("error"), "missing \\\"event\\\"")) return fail("ws: a frame without event is an error event", "");
        try a.emit("join", .{ .room = 5 });
        if (!has(try a.expect("error"), "Invalid data")) return fail("ws: data that doesn't decode is an error event", "");
        try a.emit("dance", .{});
        if (!has(try a.expect("error"), "unknown event: dance")) return fail("ws: the catch-all gets unknown events", "");
        try a.sendFrame(2, "\x00");
        if (try a.closeCode() != 1003) return fail("ws: a binary frame closes 1003", "");
    }
    {
        var h: H = .{};
        try h.start();
        defer h.stop();
        const big = try h.client("/ws/echo?name=ann");
        defer big.deinit();
        try big.send(&@as([2000]u8, @splat('x')));
        if (try big.closeCode() != 1009) return fail("ws: a message over max_payload closes 1009", "");
        const polite = try h.client("/ws/echo?name=ann");
        defer polite.deinit();
        try polite.sendFrame(8, "\x03\xe8");
        if (try polite.closeCode() != 1000) return fail("ws: a client's close is answered", "");
    }
    {
        // Pings come every heartbeat; a socket that doesn't answer is dropped.
        var h: H = .{};
        try h.start();
        defer h.stop();
        const quiet = try h.client("/ws/echo?name=ann");
        defer quiet.deinit();
        _ = try quiet.next(); // welcome
        if ((try quiet.next()).op != 9) return fail("ws: the heartbeat pings", "");
        while (true) {
            const f = quiet.next() catch break;
            if (f.op != 9) return fail("ws: a socket that misses a pong is dropped", f.data);
        }
        const lively = try h.client("/ws/echo?name=bo");
        defer lively.deinit();
        var pings: usize = 0;
        while (pings < 3) {
            const f = try lively.next();
            if (f.op == 9) {
                pings += 1;
                try lively.sendFrame(10, f.data);
            }
        }
        try lively.emit("dance", .{});
        // `expect` answers pings, so the socket is still open.
        _ = lively.expect("error") catch return fail("ws: a socket that answers pings stays", "");
    }
    {
        var h: H = .{};
        try h.start();
        const a = try h.client("/ws/echo?name=ann");
        defer a.deinit();
        _ = try a.expect("welcome");
        h.stop();
        _ = a.expect("server:draining") catch return fail("ws: shutdown runs draining first", "");
        if (try a.closeCode() != 1001) return fail("ws: shutdown closes 1001", "");
    }
}
