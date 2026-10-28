//! Boots the app for a test (KickJS's `createTestApp`): a fresh app per
//! test, with `KZIG_ENV=test` plus the given variables.
const std = @import("std");
const kzig = @import("kzig");
const App = @import("main.zig").App;

const testing = std.testing;

pub const TestApp = struct {
    app: *App,

    pub fn deinit(self: TestApp) void {
        self.app.deinit();
        testing.allocator.destroy(self.app);
    }

    pub fn request(self: TestApp, opts: kzig.testing.RequestOptions) !kzig.testing.TestResponse {
        return kzig.testing.request(testing.allocator, self.app, opts);
    }

    pub fn get(self: TestApp, target: []const u8) !kzig.testing.TestResponse {
        return self.request(.{ .target = target });
    }
};

pub fn boot(vars: []const [2][]const u8) !TestApp {
    return bootWith(vars, .{});
}

/// `boot` with services or settings replaced (`createTestApp({ overrides })`).
pub fn bootWith(vars: []const [2][]const u8, overrides: anytype) !TestApp {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("KZIG_ENV", "test");
    for (vars) |v| try env.put(v[0], v[1]);
    const app = try testing.allocator.create(App);
    errdefer testing.allocator.destroy(app);
    try app.initWith(testing.io, testing.allocator, &env, overrides);
    return .{ .app = app };
}
