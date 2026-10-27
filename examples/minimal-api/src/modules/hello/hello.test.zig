const std = @import("std");
const kzig = @import("kzig");
const App = @import("../../main.zig").App;

const testing = std.testing;

fn boot(app: *App) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try app.init(testing.io, testing.allocator, &env);
}

test "GET /api/v1/hello returns a greeting" {
    var app: App = undefined;
    try boot(&app);
    defer app.deinit();
    var res = try kzig.testing.request(testing.allocator, &app, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try testing.expectEqualStrings("Hello World from kzig!", body.message);
}

test "GET /api/v1/hello/health reports ok" {
    var app: App = undefined;
    try boot(&app);
    defer app.deinit();
    var res = try kzig.testing.request(testing.allocator, &app, .{ .target = "/api/v1/hello/health" });
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqualStrings("ok", (try res.json(struct { status: []const u8 })).status);
}

test "unknown route answers 404 problem details" {
    var app: App = undefined;
    try boot(&app);
    defer app.deinit();
    var res = try kzig.testing.request(testing.allocator, &app, .{ .target = "/api/v1/nope" });
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
    try testing.expectEqual(404, (try res.json(struct { status: u16 })).status);
}
