const std = @import("std");
const boot = @import("../../test_app.zig").boot;

const testing = std.testing;

test "GET /api/v1/hello returns a greeting" {
    const t = try boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/hello");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try testing.expectEqualStrings("Hello World from kzig!", body.message);
}

test "GET /api/v1/hello/health reports ok" {
    const t = try boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/hello/health");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqualStrings("ok", (try res.json(struct { status: []const u8 })).status);
}

test "unknown route answers 404 problem details" {
    const t = try boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/nope");
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
    try testing.expectEqual(404, (try res.json(struct { status: u16 })).status);
}
