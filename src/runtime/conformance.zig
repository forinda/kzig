//! The behaviour every runtime must share, checked over a real socket.
//! `run(Server)` takes a runtime's `Server(App)` function; each runtime's
//! tests call it. Engine-specific behaviour (timeouts, signals) is tested
//! next to the engine.
const std = @import("std");
const context = @import("../context.zig");
const router = @import("../router.zig");
const adapter = @import("../adapter.zig");
const Options = @import("options.zig").Options;

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
        /// Sends `raw` (then `then`, after reading one response), half-closes
        /// if asked, returns everything the server wrote.
        fn exchange(self: *Self, raw: []const u8, then: ?[]const u8, half_close: bool) ![]u8 {
            const s = try self.connect();
            defer s.close(testing.io);
            var rbuf: [4096]u8 = undefined;
            var r = s.reader(testing.io, &rbuf);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(testing.allocator);
            try send(s, raw);
            if (then) |next| {
                try readResponse(&r.interface, &out);
                try send(s, next);
            }
            if (half_close) try s.shutdown(testing.io, .send);
            try r.interface.appendRemaining(testing.allocator, &out, .limited(64 * 1024));
            return out.toOwnedSlice(testing.allocator);
        }
    };
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
            return std.mem.count(u8, o, "HTTP/1.1 ") == 2;
        }
    }.f },
    .{ .name = "a body on GET is not parsed as the next request", .half_close = true, .request = std.fmt.comptimePrint("GET /hello HTTP/1.1\r\nhost: x\r\ncontent-length: {d}\r\n\r\n", .{smuggled.len}) ++ smuggled, .expect = struct {
        fn f(o: []const u8) bool {
            return !has(o, "SECRET");
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
    inline for (checks) |c| {
        const expected_to_fail = comptime for (known.differences) |d| {
            if (std.mem.eql(u8, d, c.name)) break true;
        } else false;
        if (expected_to_fail) {
            if (try passes(H, c)) {
                std.debug.print("conformance: {s} now passes; drop it from the known differences\n", .{c.name});
                return error.ConformanceFailed;
            }
            continue;
        }
        var h: H = .{};
        try h.start(c.opts);
        const out = h.exchange(c.request, c.then, c.half_close) catch |err| {
            h.stop();
            std.debug.print("conformance: {s}: {t}\n", .{ c.name, err });
            return err;
        };
        defer testing.allocator.free(out);
        h.stop();
        if (!c.expect(out)) {
            std.debug.print("conformance: {s} failed; the server wrote:\n{s}\n", .{ c.name, out });
            return error.ConformanceFailed;
        }
    }
    try lifecycle(ServerFn);
}

fn passes(comptime H: type, comptime c: Check) !bool {
    var h: H = .{};
    try h.start(c.opts);
    defer h.stop();
    const out = h.exchange(c.request, c.then, c.half_close) catch return false;
    defer testing.allocator.free(out);
    return c.expect(out);
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
