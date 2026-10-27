//! The response rules every runtime applies before writing, so engines
//! can't drift apart: a status a handler may not send, bodies that must not
//! be sent, headers the engine owns.
const std = @import("std");
const builtin = @import("builtin");
const context = @import("../context.zig");

pub const Wire = struct {
    status: std.http.Status,
    body: []const u8,
};

/// A 1xx from a handler becomes 500 (a final response is required); 204,
/// 304 and HEAD carry no body (one would be read as the next response).
pub fn finish(method: std.http.Method, path: []const u8, res: *const context.Response) Wire {
    var out: Wire = .{ .status = res.status, .body = res.body };
    if (@backingInt(out.status) < 200) {
        if (!builtin.is_test) std.log.err("{t} {s}: handler set status {d}", .{ method, path, @backingInt(out.status) });
        out = .{ .status = .internal_server_error, .body = "" };
    }
    if (out.status == .no_content or out.status == .not_modified or method == .HEAD) out.body = "";
    return out;
}

/// Whether the engine may send header `h`: no CR/LF or `:` in the name
/// (header injection; std.http asserts on them), and never the framing
/// headers the engine writes itself.
pub fn sendable(h: context.Header) bool {
    if (h.name.len == 0 or std.mem.findAny(u8, h.name, ":\r\n") != null or std.mem.findAny(u8, h.value, "\r\n") != null) return false;
    return !std.ascii.eqlIgnoreCase(h.name, "content-length") and !std.ascii.eqlIgnoreCase(h.name, "transfer-encoding");
}

test "finish" {
    var res: context.Response = .{ .status = .no_content, .body = "x" };
    try std.testing.expectEqualStrings("", finish(.GET, "/", &res).body);
    res = .{ .status = .early_hints, .body = "x" };
    try std.testing.expectEqual(std.http.Status.internal_server_error, finish(.GET, "/", &res).status);
    res = .{ .status = .ok, .body = "x" };
    try std.testing.expectEqualStrings("", finish(.HEAD, "/", &res).body);
    try std.testing.expectEqualStrings("x", finish(.GET, "/", &res).body);
}

test "sendable" {
    try std.testing.expect(sendable(.{ .name = "x-a", .value = "1" }));
    try std.testing.expect(!sendable(.{ .name = "Content-Length", .value = "1" }));
    try std.testing.expect(!sendable(.{ .name = "x-a", .value = "1\r\nset-cookie: a" }));
    try std.testing.expect(!sendable(.{ .name = "a:b", .value = "1" }));
}
