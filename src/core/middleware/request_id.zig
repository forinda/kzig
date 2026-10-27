//! `x-request-id`: keeps a sane client id, otherwise generates a UUID v4,
//! and echoes it on the response (KickJS `requestId()`).
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const mw = @import("../middleware.zig");
const harness = @import("harness.zig");

pub fn requestId() mw.Fn {
    return struct {
        fn handle(ctx: *Ctx, next: *mw.Next) !void {
            const id = if (ctx.header("x-request-id")) |h| (if (valid(h)) h else try uuid(ctx)) else try uuid(ctx);
            ctx.request_id = id;
            try ctx.setHeader("x-request-id", id);
            next.run();
        }
    }.handle;
}

/// The id lands in a response header, logs and JSON: visible ASCII only.
fn valid(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

fn uuid(ctx: *Ctx) ![]const u8 {
    var b: [16]u8 = undefined;
    (ctx.io orelse return error.NoIo).random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .lower);
    return ctx.arena.print("{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

const testing = std.testing;

test "requestId keeps a valid client id" {
    var a = try harness.request(&.{requestId()}, .{ .target = "/x", .headers = &.{.{ .name = "X-Request-Id", .value = "abc-123" }} });
    defer a.deinit();
    try testing.expectEqualStrings("abc-123", a.header("x-request-id").?);
}

test "requestId replaces a bad one" {
    const huge: [200]u8 = @splat('a');
    for ([_][]const u8{ "has space", "tab\tid", &huge, "" }) |bad| {
        var a = try harness.request(&.{requestId()}, .{ .target = "/x", .headers = &.{.{ .name = "x-request-id", .value = bad }} });
        defer a.deinit();
        try testing.expectEqual(36, a.header("x-request-id").?.len);
    }
}

test "requestId generates a UUID" {
    var a = try harness.request(&.{requestId()}, .{ .target = "/x" });
    defer a.deinit();
    const id = a.header("x-request-id").?;
    try testing.expectEqual(36, id.len);
    try testing.expectEqual('4', id[14]);
    try testing.expect(std.mem.findScalar(u8, "89ab", id[19]) != null);
}

test "requestId reaches the 500 body" {
    var a = try harness.request(&.{requestId()}, .{ .target = "/boom" });
    defer a.deinit();
    try testing.expectEqual(std.http.Status.conflict, a.status);
    try testing.expect(a.header("x-request-id") != null);
}
