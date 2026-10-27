//! RFC 6455 framing for the runtimes that hand kzig the socket (`std`):
//! client frames are masked, control frames short and whole, fragments
//! joined up to a size limit. http.zig frames for itself.
const std = @import("std");
const Io = std.Io;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Message = union(enum) {
    /// Valid UTF-8; points into the buffer until the next read.
    text: []const u8,
    binary,
    /// The payload to echo in the pong.
    ping: []const u8,
    pong,
    /// The peer's code, if it sent one.
    close: ?u16,
};

pub const Error = error{ ProtocolError, TooBig, InvalidUtf8, OutOfMemory, EndOfStream, ReadFailed };

/// The close code for a read error (1002 protocol, 1009 too big, 1007 bad text).
pub fn closeCode(err: Error) u16 {
    return switch (err) {
        error.TooBig => 1009,
        error.InvalidUtf8 => 1007,
        else => 1002,
    };
}

/// Reads messages from one connection. Fragments of a data message collect
/// in `buf` (up to `max` bytes); control frames between them come back as
/// they arrive, and the message carries on with the next call.
pub const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    started: ?Opcode = null,
    control: [125]u8 = undefined,

    pub fn deinit(self: *Reader, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// The next message; its slices are valid until the next call.
    pub fn next(self: *Reader, r: *Io.Reader, gpa: std.mem.Allocator, max: usize) Error!Message {
        if (self.started == null) self.buf.clearRetainingCapacity();
        while (true) {
            const head = try r.takeArray(2);
            const fin = head[0] & 0x80 != 0;
            if (head[0] & 0x70 != 0) return error.ProtocolError;
            const op: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(head[0]))));
            if (head[1] & 0x80 == 0) return error.ProtocolError;
            const len: u64 = switch (head[1] & 0x7f) {
                126 => try r.takeInt(u16, .big),
                127 => try r.takeInt(u64, .big),
                else => |n| n,
            };
            const mask = (try r.takeArray(4)).*;
            switch (op) {
                .close, .ping, .pong => {
                    if (!fin or len > 125) return error.ProtocolError;
                    const payload = self.control[0..@intCast(len)];
                    try r.readSliceAll(payload);
                    unmask(payload, mask);
                    return switch (op) {
                        .ping => .{ .ping = payload },
                        .pong => .pong,
                        else => if (payload.len == 1)
                            error.ProtocolError
                        else
                            .{ .close = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else null },
                    };
                },
                .text, .binary, .continuation => {
                    if (op == .continuation) {
                        if (self.started == null) return error.ProtocolError;
                    } else {
                        if (self.started != null) return error.ProtocolError;
                        self.started = op;
                    }
                    if (len > max - self.buf.items.len) return error.TooBig;
                    const payload = try self.buf.addManyAsSlice(gpa, @intCast(len));
                    try r.readSliceAll(payload);
                    unmask(payload, mask);
                    if (!fin) continue;
                    const kind = self.started.?;
                    self.started = null;
                    if (kind == .binary) return .binary;
                    if (!std.unicode.utf8ValidateSlice(self.buf.items)) return error.InvalidUtf8;
                    return .{ .text = self.buf.items };
                },
                _ => return error.ProtocolError,
            }
        }
    }
};

fn unmask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*c, i| c.* ^= mask[i % 4];
}

/// One unmasked frame, flushed.
pub fn write(w: *Io.Writer, op: Opcode, payload: []const u8) Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @backingInt(op)));
    switch (payload.len) {
        0...125 => try w.writeByte(@intCast(payload.len)),
        126...0xffff => {
            try w.writeByte(126);
            try w.writeInt(u16, @intCast(payload.len), .big);
        },
        else => {
            try w.writeByte(127);
            try w.writeInt(u64, payload.len, .big);
        },
    }
    try w.writeAll(payload);
    try w.flush();
}

pub fn writeClose(w: *Io.Writer, code: u16, reason: []const u8) Io.Writer.Error!void {
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    const n = @min(reason.len, payload.len - 2);
    @memcpy(payload[2..][0..n], reason[0..n]);
    try write(w, .close, payload[0 .. 2 + n]);
}

const testing = std.testing;

/// A client frame: masked, as RFC 6455 requires of clients.
fn clientFrame(comptime fin: bool, comptime op: u4, comptime payload: []const u8) []const u8 {
    return comptime blk: {
        const mask = [4]u8{ 1, 2, 3, 4 };
        var out: []const u8 = &.{@as(u8, if (fin) 0x80 else 0) | op};
        if (payload.len < 126) {
            out = out ++ &[_]u8{0x80 | @as(u8, payload.len)};
        } else {
            out = out ++ &[_]u8{ 0x80 | 126, payload.len >> 8, payload.len & 0xff };
        }
        out = out ++ &mask;
        for (payload, 0..) |c, i| out = out ++ &[_]u8{c ^ mask[i % 4]};
        break :blk out;
    };
}

fn readOne(bytes: []const u8, max: usize) !struct { msg: Message, buf: Reader } {
    var r: std.Io.Reader = .fixed(bytes);
    var reader: Reader = .{};
    errdefer reader.deinit(testing.allocator);
    const msg = try reader.next(&r, testing.allocator, max);
    return .{ .msg = msg, .buf = reader };
}

test "a masked text frame" {
    var got = try readOne(clientFrame(true, 1, "hello"), 1024);
    defer got.buf.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", got.msg.text);
}

test "fragments join, with a ping between them" {
    const bytes = comptime clientFrame(false, 1, "hel") ++ clientFrame(true, 9, "p") ++ clientFrame(true, 0, "lo");
    var r: std.Io.Reader = .fixed(bytes);
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try testing.expectEqualStrings("p", (try reader.next(&r, testing.allocator, 1024)).ping);
    try testing.expectEqualStrings("hello", (try reader.next(&r, testing.allocator, 1024)).text);
}

test "a 16-bit length" {
    const long = "x" ++ @as([200]u8, @splat('y'));
    var got = try readOne(clientFrame(true, 1, long), 1024);
    defer got.buf.deinit(testing.allocator);
    try testing.expectEqualStrings(long, got.msg.text);
}

test "close carries its code; pong and binary are reported" {
    try testing.expectEqual(@as(?u16, 4401), (try readOne(clientFrame(true, 8, "\x11\x31bye"), 64)).msg.close);
    try testing.expectEqual(@as(?u16, null), (try readOne(clientFrame(true, 8, ""), 64)).msg.close);
    try testing.expect((try readOne(clientFrame(true, 10, ""), 64)).msg == .pong);
    var bin = try readOne(clientFrame(true, 2, "\x00"), 64);
    defer bin.buf.deinit(testing.allocator);
    try testing.expect(bin.msg == .binary);
}

test "protocol errors carry their close code" {
    // Unmasked, a reserved bit, continuation first, fragmented control, 1-byte close.
    try testing.expectError(error.ProtocolError, readOne("\x81\x01a", 64));
    try testing.expectError(error.ProtocolError, readOne(comptime &[_]u8{0xC1} ++ clientFrame(true, 1, "a")[1..], 64));
    try testing.expectError(error.ProtocolError, readOne(clientFrame(true, 0, "a"), 64));
    try testing.expectError(error.ProtocolError, readOne(clientFrame(false, 9, "a"), 64));
    try testing.expectError(error.ProtocolError, readOne(clientFrame(true, 8, "x"), 64));
    try testing.expectError(error.TooBig, readOne(clientFrame(true, 1, "toolong"), 4));
    try testing.expectError(error.InvalidUtf8, readOne(clientFrame(true, 1, "\xff"), 64));
    try testing.expectEqual(1002, closeCode(error.ProtocolError));
    try testing.expectEqual(1009, closeCode(error.TooBig));
    try testing.expectEqual(1007, closeCode(error.InvalidUtf8));
}

test "server frames are unmasked; close has a code and reason" {
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try write(&w, .text, "hi");
    try writeClose(&w, 1001, "bye");
    try testing.expectEqualSlices(u8, "\x81\x02hi\x88\x05\x03\xe9bye", w.buffered());
}
