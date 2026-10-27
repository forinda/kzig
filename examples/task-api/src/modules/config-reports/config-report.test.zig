const std = @import("std");
const test_app = @import("../../test_app.zig");
const Config = @import("../../config/config.zig").Config;

const testing = std.testing;

const Var = struct { name: []const u8, section: []const u8, origin: []const u8, required: bool };

fn originOf(vars: []const Var, name: []const u8) []const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.origin;
    return "missing";
}

test "lists every section with its origins" {
    const t = try test_app.boot(&.{.{ "FEATURES_MAX_UPLOAD_MB", "5" }});
    defer t.deinit();
    var res = try t.get("/api/v1/config");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const vars = (try res.json(struct { vars: []const Var })).vars;
    try testing.expectEqualStrings("env", originOf(vars, "FEATURES_MAX_UPLOAD_MB"));
    try testing.expectEqualStrings("default", originOf(vars, "FEATURES_SIGNUPS"));
    try testing.expectEqualStrings("dev_default", originOf(vars, "APP_PUBLIC_URL"));
    try testing.expectEqualStrings("default", originOf(vars, "PORT"));
    // Names and origins only: no value is in the report.
    try testing.expect(std.mem.indexOf(u8, res.body, "localhost:3000") == null);
}

test "is not served in production" {
    const t = try test_app.bootWith(&.{}, .{Config{ .node_env = .production }});
    defer t.deinit();
    var res = try t.get("/api/v1/config");
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
}
