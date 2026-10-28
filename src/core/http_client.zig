//! What kzig's HTTP clients (S3, Turso, D1) share over `std.http.Client`:
//! a watchdog for requests that stall, and certificate times that move on.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// std's client checks certificates against the time of its first TLS
/// request, for good: past an hour, a fresh time (certificates rotate).
pub fn refreshTlsClock(h: *std.http.Client, io: std.Io) void {
    const now = std.Io.Clock.real.now(io);
    {
        h.ca_bundle_lock.lockShared(io) catch return;
        defer h.ca_bundle_lock.unlockShared(io);
        const t = h.now orelse return;
        if (now.nanoseconds - t.nanoseconds < std.time.ns_per_hour) return;
    }
    h.ca_bundle_lock.lock(io) catch return;
    defer h.ca_bundle_lock.unlock(io);
    if (h.now != null) h.now = now;
}

/// Cuts the socket once the server has been silent for `ms`; `arm`
/// restarts the wait whenever something arrives.
pub const Watchdog = struct {
    io: Io,
    stream: Io.net.Stream,
    ms: u32,
    deadline: std.atomic.Value(i64) = .init(std.math.maxInt(i64)),
    fired: std.atomic.Value(bool) = .init(false),

    pub fn arm(w: *Watchdog) void {
        w.deadline.store(@as(i64, @intCast(@divTrunc(Io.Clock.awake.now(w.io).toNanoseconds(), std.time.ns_per_ms))) + w.ms, .release);
    }

    pub fn watch(w: *Watchdog) Io.Cancelable!void {
        while (true) {
            const now: i64 = @intCast(@divTrunc(Io.Clock.awake.now(w.io).toNanoseconds(), std.time.ns_per_ms));
            const left = w.deadline.load(.acquire) - now;
            if (left <= 0) {
                w.fired.store(true, .release);
                w.stream.shutdown(w.io, .both) catch {};
                return;
            }
            try w.io.sleep(.fromMilliseconds(@min(left, 50)), .awake);
        }
    }
};

pub const Reply = struct { status: std.http.Status, body: []u8 };

/// POST `body` (JSON) and read the answer into `a`. A server silent for
/// `timeout_ms` (0: none) is `error.Timeout`; no redirect is followed, so a
/// token in `authorization` goes nowhere else.
// ponytail: as S3, the timeout starts once connected (Io.Threaded can't time
// out a connect).
pub fn postJson(h: *std.http.Client, io: Io, a: Allocator, url: []const u8, authorization: ?[]const u8, body: []const u8, timeout_ms: u32, max_bytes: usize) !Reply {
    refreshTlsClock(h, io);
    const uri = try std.Uri.parse(url);
    var req = try h.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (authorization) |v| .{ .override = v } else .default,
            .accept_encoding = .omit,
        },
    });
    defer req.deinit();
    var dog: Watchdog = .{ .io = io, .stream = req.connection.?.stream_reader.stream, .ms = timeout_ms };
    dog.arm();
    var watching = if (timeout_ms > 0) io.concurrent(Watchdog.watch, .{&dog}) catch null else null;
    defer {
        if (watching) |*w| w.cancel(io) catch {};
        if (dog.fired.load(.acquire)) req.connection.?.closing = true;
    }
    errdefer req.connection.?.closing = true;
    const result = exchange(&req, &dog, a, body, max_bytes);
    if (dog.fired.load(.acquire)) return error.Timeout;
    return result;
}

fn exchange(req: *std.http.Client.Request, dog: *Watchdog, a: Allocator, body: []const u8, max_bytes: usize) !Reply {
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBody(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
    dog.arm();
    var redirect: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect);
    dog.arm();
    const status = response.head.status;
    var out: std.Io.Writer.Allocating = .init(a);
    var transfer: [8192]u8 = undefined;
    const rd = response.reader(&transfer);
    while (true) {
        _ = rd.stream(&out.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => |e| return e,
        };
        if (out.written().len > max_bytes) return error.ResponseTooLarge;
        dog.arm();
    }
    return .{ .status = status, .body = out.written() };
}

test "the HTTP client's TLS clock moves on: an hour-old one is replaced" {
    const testing = std.testing;
    var h: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer h.deinit();
    const now = Io.Clock.real.now(testing.io);
    h.now = .{ .nanoseconds = now.nanoseconds - 2 * std.time.ns_per_hour };
    refreshTlsClock(&h, testing.io);
    try testing.expect(now.nanoseconds - h.now.?.nanoseconds < std.time.ns_per_min);
}
