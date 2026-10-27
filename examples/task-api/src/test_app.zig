//! Boots the app for a test, like KickJS's `createTestApp`: a fresh app
//! (fresh in-memory data) per test, `NODE_ENV=test` plus the given variables.
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
    try env.put("NODE_ENV", "test");
    for (vars) |v| try env.put(v[0], v[1]);
    const app = try testing.allocator.create(App);
    errdefer testing.allocator.destroy(app);
    try app.initWith(testing.io, testing.allocator, &env, overrides);
    return .{ .app = app };
}

/// The app on a real socket (std runtime, an ephemeral port), for WebSocket
/// tests — KickJS's `app.start()` with `port: 0`.
pub const Live = struct {
    t: TestApp,
    srv: kzig.runtime.std.Server(App),
    fut: std.Io.Future(anyerror!void),

    pub fn port(self: *Live) u16 {
        return self.srv.port();
    }

    pub fn client(self: *Live, target: []const u8) !*kzig.testing.WsClient {
        return kzig.testing.WsClient.connect(testing.allocator, testing.io, self.port(), target);
    }

    /// Graceful shutdown (sockets get `draining`, then 1001), then deinit.
    pub fn stop(self: *Live) void {
        self.srv.shutdown();
        self.fut.cancel(testing.io) catch {};
        self.srv.deinit();
        self.t.deinit();
        testing.allocator.destroy(self);
    }

    fn run(srv: *kzig.runtime.std.Server(App)) anyerror!void {
        return srv.run();
    }
};

/// `heartbeat_ms` replaces the App's for this test.
pub fn listen(vars: []const [2][]const u8, heartbeat_ms: ?u32) !*Live {
    const live = try testing.allocator.create(Live);
    errdefer testing.allocator.destroy(live);
    live.t = try boot(vars);
    errdefer live.t.deinit();
    if (heartbeat_ms) |ms| live.t.app.ws_hub.opts.heartbeat_ms = ms;
    live.srv = try .init(testing.io, testing.allocator, live.t.app, .{ .port = 0 });
    live.fut = try testing.io.concurrent(Live.run, .{&live.srv});
    return live;
}
