//! A WebSocket connection once a runtime owns the socket and has sent the
//! 101: frames in, the App's gateway hooks, frames out. Both runtimes run it,
//! so the socket is closed by the runtime only after the App let go of it.
const std = @import("std");
const ws = @import("../ws.zig");
const frame = @import("frame.zig");

const Io = std.Io;

/// `Sec-WebSocket-Accept` for a client's key.
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

pub const Refusal = enum { bad_request, upgrade_required };

/// A handshake needs a key and version 13 (RFC 6455 §4.2.2: another version
/// is 426 with `sec-websocket-version: 13`).
pub fn check(key: ?[]const u8, version: ?[]const u8) ?Refusal {
    if (key == null or key.?.len == 0) return .bad_request;
    const v = version orelse return .bad_request;
    if (!std.mem.eql(u8, std.mem.trim(u8, v, " "), "13")) return .upgrade_required;
    return null;
}

/// Runs until either side closes; the caller then closes the socket.
pub fn serve(comptime App: type, app: *App, io: Io, gpa: std.mem.Allocator, stream: Io.net.Stream, r: *Io.Reader, w: *Io.Writer, gateway: usize, upgrade: ws.Upgrade) void {
    var conn: Conn = .{ .io = io, .stream = stream, .w = w, .timeout_ms = App.ws_options.write_timeout_ms };
    var dog = if (conn.timeout_ms > 0) io.concurrent(Conn.watch, .{&conn}) catch null else null;
    defer if (dog) |*d| d.cancel(io) catch {};

    // The app's hooks run whole even when the runtime is cancelled.
    var prev = io.swapCancelProtection(.blocked);
    const opened = app.wsOpen(gateway, conn.conn(), upgrade) catch null;
    _ = io.swapCancelProtection(prev);
    const session = opened orelse return;
    defer {
        prev = io.swapCancelProtection(.blocked);
        app.wsClose(session);
        _ = io.swapCancelProtection(prev);
    }

    var reader: frame.Reader = .{};
    defer reader.deinit(gpa);
    while (true) {
        const msg = reader.next(r, gpa, App.ws_options.max_payload) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed, error.OutOfMemory => return,
            error.ProtocolError, error.TooBig, error.InvalidUtf8 => |e| return session.close(frame.closeCode(e), ""),
        };
        prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        const closing = session.closed.load(.acquire);
        switch (msg) {
            // After our close frame, only the client's close matters.
            .text => |text| if (!closing) app.wsMessage(session, text),
            .binary => session.close(1003, "Binary frames are not supported"),
            .ping => |payload| if (!closing) conn.pong(payload),
            .pong => app.wsPong(session),
            .close => |code| return session.close(if (code) |c| (if (sendable(c)) c else 1002) else 1000, ""),
        }
    }
}

/// Codes a peer may put in a close frame (RFC 6455 §7.4).
fn sendable(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

/// The socket's writer, shared by its own task and broadcasts from others.
/// A write that waits past `timeout_ms` (a client that stopped reading) gets
/// the socket shut, which fails it, so it can't hold the hub up.
const Conn = struct {
    io: Io,
    stream: Io.net.Stream,
    w: *Io.Writer,
    timeout_ms: u32,
    mutex: Io.Mutex = .init,
    /// When the write in progress must end; max while idle.
    deadline: std.atomic.Value(i64) = .init(std.math.maxInt(i64)),

    const vtable: ws.Conn.VTable = .{ .send = Conn.send, .ping = Conn.ping, .close = Conn.close };

    fn conn(self: *Conn) ws.Conn {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn write(self: *Conn, op: frame.Opcode, payload: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.timeout_ms > 0) self.deadline.store(nowMs(self.io) + self.timeout_ms, .release);
        defer self.deadline.store(std.math.maxInt(i64), .release);
        try frame.write(self.w, op, payload);
    }

    fn send(ptr: *anyopaque, data: []const u8) anyerror!void {
        const self: *Conn = @ptrCast(@alignCast(ptr));
        try self.write(.text, data);
    }

    fn ping(ptr: *anyopaque) anyerror!void {
        const self: *Conn = @ptrCast(@alignCast(ptr));
        try self.write(.ping, "");
    }

    fn pong(self: *Conn, payload: []const u8) void {
        self.write(.pong, payload) catch {};
    }

    /// A close frame, then no more sending; the client answers and hangs up.
    /// Code 0 drops the socket.
    fn close(ptr: *anyopaque, code: u16, reason: []const u8) void {
        const self: *Conn = @ptrCast(@alignCast(ptr));
        if (code != 0) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            frame.writeClose(self.w, code, reason) catch {};
        }
        self.stream.shutdown(self.io, if (code == 0) .both else .send) catch {};
    }

    fn watch(self: *Conn) Io.Cancelable!void {
        while (true) {
            const left = self.deadline.load(.acquire) - nowMs(self.io);
            if (left <= 0) {
                self.stream.shutdown(self.io, .both) catch {};
                return;
            }
            try self.io.sleep(.fromMilliseconds(@min(left, 100)), .awake);
        }
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).toNanoseconds(), std.time.ns_per_ms));
}

test "acceptKey matches RFC 6455's example" {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "check wants a key and version 13" {
    try std.testing.expectEqual(null, check("k", "13"));
    try std.testing.expectEqual(Refusal.bad_request, check(null, "13"));
    try std.testing.expectEqual(Refusal.upgrade_required, check("k", "8"));
}
