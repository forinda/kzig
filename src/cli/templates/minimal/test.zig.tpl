const std = @import("std");
const test_app = @import("../../test_app.zig");

const testing = std.testing;

test "GET /api/v1/{{plural}}" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/{{plural}}");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
}
