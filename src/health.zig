//! KickJS's built-in health module: `GET /health/live` and `GET /health/ready`,
//! mounted without the api prefix or version. Adapter checks and draining
//! arrive with lifecycle (M5).
const app = @import("app.zig");
const Ctx = @import("context.zig").Ctx;

pub const Check = struct {
    name: []const u8,
    status: []const u8,
};

pub const HealthController = struct {
    process: *const app.Process,

    pub const routes = .{
        .{ .method = .GET, .path = "/live", .handler = "live" },
        .{ .method = .GET, .path = "/ready", .handler = "ready" },
    };

    pub fn live(self: *HealthController, _: *Ctx) struct { status: []const u8, uptime: f64 } {
        return .{ .status = "ok", .uptime = self.process.uptime() };
    }

    pub fn ready(_: *HealthController, _: *Ctx) struct { status: []const u8, checks: []const Check } {
        return .{ .status = "ready", .checks = &.{} };
    }
};

pub const Module = app.Module(.{
    .name = "HealthModule",
    .path = "/health",
    .controllers = &.{HealthController},
    .prefix = false,
    .version = false,
});
