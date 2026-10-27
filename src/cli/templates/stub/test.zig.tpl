const std = @import("std");
const test_app = @import("{{root}}test_app.zig");

const testing = std.testing;

test "{{kebab}}" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/health/live");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
}
