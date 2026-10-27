//! The `std.http.Server` runtime: one task per connection on an `Io.Group`,
//! a connection cap, and size/time limits at the edge.
const std = @import("std");
const builtin = @import("builtin");
const context = @import("../context.zig");
const router = @import("../router.zig");

const Io = std.Io;
const Ctx = context.Ctx;
const http = std.http;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    /// 0 picks an ephemeral port; read it back with `Server.port`.
    port: u16 = 3000,
    max_connections: u32 = 1024,
    /// KickJS's default `jsonLimit` is 1mb.
    max_body_bytes: usize = 1 << 20,
    /// The whole request head must fit; larger answers 431.
    max_header_bytes: usize = 16 * 1024,
    /// Time a connection may sit between bytes before it is closed.
    read_timeout_ms: u32 = 30_000,
};

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: std.mem.Allocator,
        options: Options,
        listener: Io.net.Server,
        permits: Io.Semaphore,

        pub fn init(io: Io, gpa: std.mem.Allocator, options: Options) !Self {
            const address = try Io.net.IpAddress.parse(options.host, options.port);
            return .{
                .io = io,
                .gpa = gpa,
                .options = options,
                .listener = try address.listen(io, .{ .reuse_address = true }),
                .permits = .{ .permits = options.max_connections },
            };
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit(self.io);
        }

        pub fn port(self: *const Self) u16 {
            return self.listener.socket.address.getPort();
        }

        /// Accepts until canceled; canceling also cancels open connections.
        pub fn run(self: *Self) !void {
            const io = self.io;
            var group: Io.Group = .init;
            defer group.cancel(io);
            while (true) {
                // Taken before accept, so a full server leaves new clients in
                // the kernel backlog instead of spawning without bound.
                try self.permits.wait(io);
                const stream = self.listener.accept(io) catch |err| {
                    self.permits.post(io);
                    return err;
                };
                // `concurrent`, not `async`: `async` may run the connection
                // inline and stop the accept loop.
                group.concurrent(io, serveConnection, .{ self, stream }) catch {
                    stream.close(io);
                    self.permits.post(io);
                };
            }
        }

        fn serveConnection(self: *Self, stream: Io.net.Stream) void {
            const io = self.io;
            defer {
                stream.close(io);
                self.permits.post(io);
            }
            var deadline: std.atomic.Value(i64) = .init(std.math.maxInt(i64));
            var dog = if (self.options.read_timeout_ms > 0)
                io.concurrent(watchdog, .{ io, stream, &deadline }) catch null
            else
                null;
            defer if (dog) |*d| d.cancel(io) catch {};
            const timeout_ms = self.options.read_timeout_ms;

            const read_buf = self.gpa.alloc(u8, self.options.max_header_bytes) catch return;
            defer self.gpa.free(read_buf);
            var write_buf: [8192]u8 = undefined;
            var sr = stream.reader(io, read_buf);
            var sw = stream.writer(io, &write_buf);
            var server = http.Server.init(&sr.interface, &sw.interface);
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();

            while (true) {
                _ = arena.reset(.retain_capacity);
                arm(io, &deadline, timeout_ms);
                var req = server.receiveHead() catch |err| {
                    const status: http.Status = switch (err) {
                        error.HttpHeadersOversize => .request_header_fields_too_large,
                        error.HttpHeadersInvalid => .bad_request,
                        else => return,
                    };
                    writeRaw(&sw.interface, status);
                    return lingerClose(io, stream, &sr.interface);
                };
                switch (self.serveRequest(&req, arena.allocator(), &deadline) catch return) {
                    .keep_alive => {},
                    .close => return,
                    .linger => return lingerClose(io, stream, &sr.interface),
                }
            }
        }

        fn serveRequest(self: *Self, req: *http.Server.Request, arena: std.mem.Allocator, deadline: *std.atomic.Value(i64)) !Next {
            const io = self.io;
            // Reading the body invalidates the head's strings, so copy first.
            const target = try arena.dupe(u8, req.head.target);
            var headers: std.ArrayList(context.Header) = .empty;
            var it = req.iterateHeaders();
            while (it.next()) |h| try headers.append(arena, .{
                .name = try arena.dupe(u8, h.name),
                .value = try arena.dupe(u8, h.value),
            });
            const method = req.head.method;
            const keep_alive = req.head.keep_alive;

            const max = self.options.max_body_bytes;
            if (req.head.content_length) |len| if (len > max) return tooLarge(req);
            var body: []const u8 = "";
            // RFC 9112 §6.3: a request with neither header has no body; reading
            // to EOF would swallow the next request on the connection.
            const has_body = req.head.content_length != null or req.head.transfer_encoding != .none;
            if (method.requestHasBody() and has_body) {
                var body_buf: [4096]u8 = undefined;
                const r = try req.readerExpectContinue(&body_buf);
                body = r.allocRemaining(arena, .limited(max)) catch |err| switch (err) {
                    error.StreamTooLong => return tooLarge(req),
                    else => return err,
                };
            } else if (method.requestHasBody()) {
                // std.http asserts a body-carrying method has a length when it
                // discards the body before responding; there is none to discard.
                req.server.reader.state = .ready;
            }

            const q = std.mem.indexOfScalar(u8, target, '?');
            const request: context.Request = .{
                .method = method,
                .path = if (q) |i| target[0..i] else target,
                .query = if (q) |i| target[i + 1 ..] else "",
                .headers = headers.items,
                .body = body,
            };
            var res: context.Response = .{};
            var ctx: Ctx = .{ .arena = arena, .req = &request, .res = &res };
            // The timeout bounds the client, not the handler.
            deadline.store(std.math.maxInt(i64), .monotonic);
            App.handle(&ctx);
            arm(io, deadline, self.options.read_timeout_ms);

            const out = try arena.alloc(http.Header, res.headers.items.len);
            var n: usize = 0;
            for (res.headers.items) |h| {
                // std asserts on these; drop the header rather than crash.
                if (h.name.len == 0 or std.mem.indexOfAny(u8, h.name, ":\r\n") != null or std.mem.indexOfAny(u8, h.value, "\r\n") != null) continue;
                out[n] = .{ .name = h.name, .value = h.value };
                n += 1;
            }
            try req.respond(res.body, .{ .status = res.status, .keep_alive = keep_alive, .extra_headers = out[0..n] });
            return if (keep_alive) .keep_alive else .close;
        }

        fn tooLarge(req: *http.Server.Request) !Next {
            try req.respond(problem_413, .{
                .status = .payload_too_large,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/problem+json" }},
            });
            return .linger;
        }
    };
}

/// What to do with a connection after a request.
const Next = enum {
    keep_alive,
    close,
    /// Closing with unread request bytes makes the kernel send RST, which can
    /// destroy the error response before the client reads it.
    linger,
};

/// Stops sending, then drains a bounded amount of what the client still
/// sends, so the response arrives before the connection closes.
fn lingerClose(io: Io, stream: Io.net.Stream, r: *Io.Reader) void {
    stream.shutdown(io, .send) catch return;
    var left: usize = 64 * 1024;
    while (left > 0) {
        const n = r.discard(.limited(left)) catch return;
        if (n == 0) return;
        left -= n;
    }
}

const problem_413 = "{\"type\":\"about:blank\",\"title\":\"Payload Too Large\",\"status\":413}";

/// For errors before there is a request to respond through; the connection closes after.
fn writeRaw(w: *Io.Writer, status: http.Status) void {
    w.print("HTTP/1.1 {d} {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{
        @backingInt(status), status.phrase() orelse "",
    }) catch return;
    w.flush() catch return;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).toNanoseconds(), std.time.ns_per_ms));
}

/// Restarts the client's time budget; 0 disables it.
fn arm(io: Io, deadline: *std.atomic.Value(i64), timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    deadline.store(nowMs(io) + timeout_ms, .monotonic);
}

// ponytail: one watchdog task per connection (a second thread under
// Io.Threaded). A single reaper over all connections scales better if
// thread count matters.
/// Shuts the socket down once the deadline passes, which unblocks the
/// connection's pending read or write. Socket-level timeouts don't work here:
/// Io.Threaded treats the resulting EAGAIN as a bug and panics.
fn watchdog(io: Io, stream: Io.net.Stream, deadline: *std.atomic.Value(i64)) Io.Cancelable!void {
    while (true) {
        const left = deadline.load(.monotonic) - nowMs(io);
        if (left <= 0) {
            stream.shutdown(io, .both) catch {};
            return;
        }
        try io.sleep(.fromMilliseconds(@min(left, 1000)), .awake);
    }
}

const testing = std.testing;

/// `"a" ** n` — the `**` operator is gone in Zig 0.17.
fn fill(comptime n: usize, comptime c: u8) [n]u8 {
    return @splat(c);
}

const TestApp = router.Router(&.{
    router.route(.GET, "/hello", struct {
        fn f(_: *Ctx) []const u8 {
            return "hi";
        }
    }.f),
    router.route(.POST, "/echo", struct {
        fn f(ctx: *Ctx) []const u8 {
            return ctx.req.body;
        }
    }.f),
});

/// Starts a server on an ephemeral port, sends `raw`, returns everything the
/// server wrote until it closed the connection.
fn roundTrip(opts: Options, raw: []const u8) ![]u8 {
    return roundTripOpts(opts, raw, false);
}

fn roundTripOpts(opts: Options, raw: []const u8, half_close: bool) ![]u8 {
    const io = testing.io;
    var o = opts;
    o.port = 0;
    var srv: Server(TestApp) = try .init(io, testing.allocator, o);
    defer srv.deinit();
    var fut = try io.concurrent(Server(TestApp).run, .{&srv});
    defer fut.cancel(io) catch {};

    const addr = try Io.net.IpAddress.parse("127.0.0.1", srv.port());
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(raw);
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    if (half_close) try stream.shutdown(io, .send);
    return r.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
}

test "serves a route" {
    const out = try roundTrip(.{}, "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhi"));
}

test "keep-alive serves two requests on one connection" {
    const out = try roundTrip(.{},
        \\GET /hello HTTP/1.1
    ++ "\r\nhost: x\r\n\r\n" ++
        \\GET /hello HTTP/1.1
    ++ "\r\nhost: x\r\nconnection: close\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expectEqual(2, std.mem.count(u8, out, "HTTP/1.1 200 OK"));
}

test "request body reaches the handler" {
    const out = try roundTrip(.{}, "POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 5\r\nconnection: close\r\n\r\nhello");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhello"));
}

test "content-length over limit is 413" {
    const out = try roundTrip(.{ .max_body_bytes = 16 }, "POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 100\r\n\r\n" ++ comptime fill(100, 'a'));
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 413 "));
}

test "chunked body over limit is 413" {
    const out = try roundTrip(.{ .max_body_bytes = 16 }, "POST /echo HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n" ++
        "10\r\n" ++ comptime fill(16, 'a') ++ "\r\n10\r\n" ++ fill(16, 'b') ++ "\r\n0\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 413 "));
}

test "oversized headers are 431" {
    const out = try roundTrip(.{ .max_header_bytes = 1024 }, "GET /hello HTTP/1.1\r\nx-big: " ++ comptime fill(2000, 'a') ++ "\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 431 "));
}

test "POST without content-length has an empty body" {
    // Half-close so a server that wrongly reads to EOF can't hang the test;
    // it would swallow the GET as the POST's body and answer once.
    const out = try roundTripOpts(.{}, "POST /echo HTTP/1.1\r\nhost: x\r\n\r\n" ++
        "GET /hello HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n", true);
    defer testing.allocator.free(out);
    try testing.expectEqual(2, std.mem.count(u8, out, "HTTP/1.1 "));
}

test "idle connection is closed after read_timeout_ms" {
    // A partial head that never completes (slowloris); the server must hang up.
    const out = try roundTrip(.{ .read_timeout_ms = 100 }, "GET /hello HTTP/1.1\r\nhost: x\r\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}
