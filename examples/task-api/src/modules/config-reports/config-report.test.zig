const std = @import("std");
const test_app = @import("../../test_app.zig");

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
    try testing.expect(std.mem.find(u8, res.body, "localhost:3000") == null);
}

test "is not served in production" {
    var key_buf: [64]u8 = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NODE_ENV", "production");
    try env.put("APP_PUBLIC_URL", "https://api.example.com");
    try env.put("API_KEY", "prod-api-key-0123456789abcdef0123456");
    try env.put("SIGNING_SECRET", "prod-signing-secret-0123456789abcdef");
    try env.put("CHAT_SECRET", "prod-chat-secret-0123456789abcdef0123");
    try env.put("CRON_SECRET", "prod-cron-secret-0123456789");
    try env.put("STORAGE_DRIVER", "disk");
    for ([_][]const u8{ "TRANSACTIONAL_MAIL", "MARKETING_MAIL" }) |m| {
        try env.put(try std.mem.print(&key_buf, "{s}_PASSWORD", .{m}), "a-long-password");
        try env.put(try std.mem.print(&key_buf, "{s}_FROM", .{m}), "noreply@example.com");
    }
    const App = @import("../../main.zig").App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    const t: test_app.TestApp = .{ .app = app };
    var res = try t.get("/api/v1/config");
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
}

test "is not served when NODE_ENV is unset" {
    var key_buf: [64]u8 = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("APP_PUBLIC_URL", "https://api.example.com");
    try env.put("API_KEY", "prod-api-key-0123456789abcdef0123456");
    try env.put("SIGNING_SECRET", "prod-signing-secret-0123456789abcdef");
    try env.put("CHAT_SECRET", "prod-chat-secret-0123456789abcdef0123");
    try env.put("CRON_SECRET", "prod-cron-secret-0123456789");
    try env.put("STORAGE_DRIVER", "disk");
    for ([_][]const u8{ "TRANSACTIONAL_MAIL", "MARKETING_MAIL" }) |m| {
        try env.put(try std.mem.print(&key_buf, "{s}_PASSWORD", .{m}), "a-long-password");
        try env.put(try std.mem.print(&key_buf, "{s}_FROM", .{m}), "noreply@example.com");
    }
    const App = @import("../../main.zig").App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    var res = try @import("kzig").testing.request(testing.allocator, app, .{ .target = "/api/v1/config" });
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
}
