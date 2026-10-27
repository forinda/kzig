//! In-process runtime: drives the full pipeline without a socket, the way
//! KickJS's `createTestApp` drives `app.handle`.
const std = @import("std");
const context = @import("context.zig");
const router = @import("router.zig");

const Ctx = context.Ctx;
const Header = context.Header;

pub const RequestOptions = struct {
    method: std.http.Method = .GET,
    /// Path plus optional `?query`.
    target: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const TestResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: std.http.Status,
    headers: []const Header,
    body: []const u8,

    pub fn deinit(self: *TestResponse) void {
        self.arena.deinit();
    }

    pub fn header(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// Parses the body into `T`; unknown fields are ignored.
    pub fn json(self: *TestResponse, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), self.body, .{ .ignore_unknown_fields = true });
    }
};

/// Runs one request through `app.handle` — an `*App`, or a `Router(...)` value.
pub fn request(gpa: std.mem.Allocator, app: anytype, opts: RequestOptions) !TestResponse {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const q = std.mem.findScalar(u8, opts.target, '?');
    const req: context.Request = .{
        .method = opts.method,
        .path = if (q) |i| opts.target[0..i] else opts.target,
        .query = if (q) |i| opts.target[i + 1 ..] else "",
        .headers = opts.headers,
        .body = opts.body,
    };
    var res: context.Response = .{};
    var ctx: Ctx = .{ .arena = arena.allocator(), .req = &req, .res = &res };
    app.handle(&ctx);
    return .{ .arena = arena, .status = res.status, .headers = res.headers.items, .body = res.body };
}

// The shape of kickjs-examples-archive/minimal-api, minus modules (M2).
const Hello = struct {
    fn index(_: *Ctx) struct { message: []const u8 } {
        return .{ .message = "Hello World from kzig!" };
    }
    fn health(_: *Ctx) struct { status: []const u8 } {
        return .{ .status = "ok" };
    }
};

const App = router.Router(&.{
    router.route(.GET, "/api/v1/hello", Hello.index),
    router.route(.GET, "/api/v1/hello/health", Hello.health),
});

test "GET /api/v1/hello returns a greeting" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try std.testing.expectEqualStrings("Hello World from kzig!", body.message);
}

test "GET /api/v1/hello/health reports ok" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/hello/health" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", (try res.json(struct { status: []const u8 })).status);
}

test "unknown route answers 404 problem details" {
    var res = try request(std.testing.allocator, App{}, .{ .target = "/api/v1/nope" });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqual(404, (try res.json(struct { status: u16 })).status);
    try std.testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
}

test "query string reaches the handler" {
    const Echo = struct {
        fn q(ctx: *Ctx) !?[]const u8 {
            return ctx.query("name");
        }
    };
    const R = router.Router(&.{router.route(.GET, "/echo", Echo.q)});
    var res = try request(std.testing.allocator, R{}, .{ .target = "/echo?name=ada" });
    defer res.deinit();
    try std.testing.expectEqualStrings("\"ada\"", res.body);
}

/// A WebSocket client for socket tests (KickJS's tests use `ws`): the
/// handshake, masked text frames, server frames read back. It gives up
/// after 5 s, so a server that never answers fails the test.
pub const WsClient = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    rbuf: [16 * 1024]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    guard: ?std.Io.Future(std.Io.Cancelable!void) = null,
    /// The handshake's status: 101, or what the server answered instead.
    status: u16 = 0,
    data: std.ArrayList(u8) = .empty,

    pub const Frame = struct {
        op: u4,
        /// Valid until the next read.
        data: []const u8,

        pub fn closeCode(f: Frame) ?u16 {
            return if (f.op == 8 and f.data.len >= 2) std.mem.readInt(u16, f.data[0..2], .big) else null;
        }
    };

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, port: u16, target: []const u8) !*WsClient {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var tries: usize = 0;
        // A runtime may bind after `run` starts.
        const stream = while (true) : (tries += 1) {
            break addr.connect(io, .{ .mode = .stream }) catch |err| {
                if (tries > 200) return err;
                try io.sleep(.fromMilliseconds(5), .awake);
                continue;
            };
        };
        const c = try gpa.create(WsClient);
        c.* = .{ .io = io, .gpa = gpa, .stream = stream };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        c.guard = io.concurrent(giveUp, .{ io, stream }) catch null;
        errdefer c.deinit();
        const w = &c.writer.interface;
        try w.print("GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" ++
            "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n", .{target});
        try w.flush();
        const r = &c.reader.interface;
        const status_line = try r.takeDelimiterInclusive('\n');
        c.status = std.fmt.parseInt(u16, status_line[9..12], 10) catch 0;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        return c;
    }

    fn giveUp(io: std.Io, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        try io.sleep(.fromSeconds(5), .awake);
        stream.shutdown(io, .both) catch {};
    }

    pub fn deinit(c: *WsClient) void {
        if (c.guard) |*g| g.cancel(c.io) catch {};
        c.stream.close(c.io);
        c.data.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    /// A masked frame with `op` (1 text, 2 binary, 8 close, 10 pong).
    pub fn sendFrame(c: *WsClient, op: u4, payload: []const u8) !void {
        const w = &c.writer.interface;
        try w.writeByte(0x80 | @as(u8, op));
        if (payload.len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= 0xffff) {
            try w.writeByte(0x80 | 126);
            try w.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try w.writeByte(0x80 | 127);
            try w.writeInt(u64, payload.len, .big);
        }
        const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
        try w.writeAll(&mask);
        for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
        try w.flush();
    }

    pub fn send(c: *WsClient, text: []const u8) !void {
        return c.sendFrame(1, text);
    }

    /// `{"event":…,"data":…}`.
    pub fn emit(c: *WsClient, event: []const u8, data: anytype) !void {
        const text = try std.json.Stringify.valueAlloc(c.gpa, .{ .event = event, .data = data }, .{});
        defer c.gpa.free(text);
        try c.send(text);
    }

    /// The next frame from the server.
    pub fn next(c: *WsClient) !Frame {
        const r = &c.reader.interface;
        const head = try r.takeArray(2);
        const len: u64 = switch (head[1] & 0x7f) {
            126 => try r.takeInt(u16, .big),
            127 => try r.takeInt(u64, .big),
            else => |n| n,
        };
        c.data.clearRetainingCapacity();
        try r.readSliceAll(try c.data.addManyAsSlice(c.gpa, @intCast(len)));
        return .{ .op = @truncate(head[0]), .data = c.data.items };
    }

    /// The text of the next `event` frame. Pings are answered; frames for
    /// other events are skipped; a close frame is an error.
    pub fn expect(c: *WsClient, event: []const u8) ![]const u8 {
        while (true) {
            const f = try c.next();
            switch (f.op) {
                9 => try c.sendFrame(10, f.data),
                8 => return error.Closed,
                1 => {
                    var needle_buf: [128]u8 = undefined;
                    const needle = try std.fmt.bufPrint(&needle_buf, "{{\"event\":\"{s}\"", .{event});
                    if (std.mem.startsWith(u8, f.data, needle)) return f.data;
                },
                else => {},
            }
        }
    }

    /// The code of the server's close frame (pings answered, other frames
    /// skipped); null if the socket ended without one.
    pub fn closeCode(c: *WsClient) !?u16 {
        while (true) {
            const f = c.next() catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return null,
                else => return err,
            };
            switch (f.op) {
                8 => return f.closeCode(),
                9 => c.sendFrame(10, f.data) catch {},
                else => {},
            }
        }
    }
};
