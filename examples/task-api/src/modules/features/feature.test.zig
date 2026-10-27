const std = @import("std");
const test_app = @import("../../test_app.zig");
const FeaturesService = @import("feature.service.zig").FeaturesService;
const FeatureSettings = @import("feature.settings.zig").FeatureSettings;

const testing = std.testing;

const Current = struct { app: []const u8, signupUrl: ?[]const u8, betaBanner: bool, maxUploadBytes: u64 };

test "injects its section into the service, parsed from the env" {
    const t = try test_app.boot(&.{
        .{ "FEATURES_BETA_TESTERS", "ann@example.com,bob@example.com" },
        .{ "FEATURES_SIGNUPS", "false" },
    });
    defer t.deinit();
    var res = try t.get("/api/v1/features");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqualStrings("{\"app\":\"task-api\",\"signupUrl\":null,\"betaBanner\":false,\"maxUploadBytes\":10485760}", res.body);
    // The list is read server-side only; the endpoint takes no email.
    const features = t.app.get(FeaturesService);
    try testing.expect(features.isBetaTester("Ann@example.com"));
    try testing.expect(!features.isBetaTester("eve@example.com"));
    var probe = try t.get("/api/v1/features?email=ann@example.com");
    defer probe.deinit();
    try testing.expect(!(try probe.json(Current)).betaBanner);
}

test "takes a provided value instead of the environment" {
    const t = try test_app.bootWith(&.{}, .{FeatureSettings{ .max_upload_mb = 1 }});
    defer t.deinit();
    var res = try t.get("/api/v1/features");
    defer res.deinit();
    const body = try res.json(Current);
    try testing.expectEqualStrings("http://localhost:3000/signup", body.signupUrl.?);
    try testing.expectEqual(1048576, body.maxUploadBytes);
}

test "secrets fail closed: no dev default outside development and test" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("DB_FILE", ":memory:"); // not ./data/app.db
    try env.put("NODE_ENV", "production");
    const App = @import("../../main.zig").App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try testing.expectError(error.InvalidConfig, app.init(testing.io, testing.allocator, &env));
}
