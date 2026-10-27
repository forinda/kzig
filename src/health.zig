//! KickJS's built-in health module: `GET /health/live` and `GET /health/ready`,
//! mounted without the api prefix or version. Ready runs every adapter's
//! `onHealthCheck`; both report draining once shutdown has begun.
const std = @import("std");
const app = @import("app.zig");
const Ctx = @import("context.zig").Ctx;

pub const HealthCheck = struct {
    name: []const u8,
    status: enum { up, down },
};

/// One check's result, written by the task running it.
pub const Slot = struct {
    done: std.atomic.Value(bool) = .init(false),
    value: HealthCheck = undefined,

    pub fn store(self: *Slot, v: HealthCheck) void {
        self.value = v;
        self.done.store(true, .release);
    }

    pub fn get(self: *const Slot) ?HealthCheck {
        return if (self.done.load(.acquire)) self.value else null;
    }
};

pub fn runCheck(comptime A: type) fn (*A, *Slot) void {
    return struct {
        fn f(a: *A, slot: *Slot) void {
            slot.store(a.onHealthCheck());
        }
    }.f;
}

/// Until every slot is done or `ms` passed.
pub fn waitAll(io: std.Io, slots: []const Slot, ms: i64) void {
    const start = std.Io.Clock.awake.now(io);
    for (slots) |*s| while (s.get() == null) {
        const elapsed = @divTrunc(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), std.time.ns_per_ms);
        if (elapsed >= ms) return;
        io.sleep(.fromMilliseconds(5), .awake) catch return;
    };
}

/// How the health controller reaches the app's adapters; seeded by `App`.
pub const Probe = struct {
    /// Set by App (optional only so DI treats it as a plain field).
    app: ?*anyopaque = null,
    checks: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const HealthCheck = noChecks,
};

fn noChecks(_: *anyopaque, _: std.mem.Allocator) anyerror![]const HealthCheck {
    return &.{};
}

pub const HealthController = struct {
    process: *const app.Process,
    probe: *const Probe,

    pub const routes = .{
        .{ .method = .GET, .path = "/live", .handler = "live" },
        .{ .method = .GET, .path = "/ready", .handler = "ready" },
    };

    pub fn live(self: *HealthController, _: *Ctx) struct { status: []const u8, uptime: f64 } {
        return .{ .status = if (self.process.isDraining()) "draining" else "ok", .uptime = self.process.uptime() };
    }

    /// 200 only when every check is up; 503 while draining or degraded, so
    /// a load balancer stops sending traffic.
    pub fn ready(self: *HealthController, ctx: *Ctx) !struct { status: []const u8, checks: []const HealthCheck } {
        if (self.process.isDraining()) {
            ctx.status(.service_unavailable);
            return .{ .status = "draining", .checks = &.{} };
        }
        const checks = try self.probe.checks(self.probe.app.?, ctx.arena);
        for (checks) |c| if (c.status == .down) {
            ctx.status(.service_unavailable);
            return .{ .status = "degraded", .checks = checks };
        };
        return .{ .status = "ready", .checks = checks };
    }
};

pub const Module = app.Module(.{
    .name = "HealthModule",
    .path = "/health",
    .controllers = &.{HealthController},
    .prefix = false,
    .version = false,
});

const testing = std.testing;
const testing_rt = @import("testing.zig");

const Up = struct {
    pub fn onHealthCheck(_: *Up) HealthCheck {
        return .{ .name = "db", .status = .up };
    }
};
const Toggle = struct {
    down: bool = false,
    pub fn onHealthCheck(self: *Toggle) HealthCheck {
        return .{ .name = "mail", .status = if (self.down) .down else .up };
    }
};

const ProbeApp = app.App(.{ .modules = &.{}, .adapters = &.{ Up, Toggle } });

fn boot(a: *ProbeApp) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.init(testing.io, testing.allocator, &env);
}

test "ready aggregates adapter checks" {
    var a: ProbeApp = undefined;
    try boot(&a);
    defer a.deinit();
    var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
    defer res.deinit();
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{\"status\":\"ready\",\"checks\":[{\"name\":\"db\",\"status\":\"up\"},{\"name\":\"mail\",\"status\":\"up\"}]}", res.body);
}

test "degraded is 503" {
    var a: ProbeApp = undefined;
    try boot(&a);
    defer a.deinit();
    a.get(Toggle).down = true;
    var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
    defer res.deinit();
    try testing.expectEqual(std.http.Status.service_unavailable, res.status);
    try testing.expect(std.mem.startsWith(u8, res.body, "{\"status\":\"degraded\""));
}

test "draining is 503 and live says draining" {
    var a: ProbeApp = undefined;
    try boot(&a);
    defer a.deinit();
    a.beginDrain();
    var ready = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
    defer ready.deinit();
    try testing.expectEqual(std.http.Status.service_unavailable, ready.status);
    try testing.expectEqualStrings("{\"status\":\"draining\",\"checks\":[]}", ready.body);
    var live = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/live" });
    defer live.deinit();
    try testing.expectEqualStrings("draining", (try live.json(struct { status: []const u8 })).status);
}

var slow_runs: std.atomic.Value(u32) = .init(0);

fn Slow(comptime ms: i64, comptime label: []const u8) type {
    return struct {
        process: *const app.Process,
        pub fn onHealthCheck(self: *@This()) HealthCheck {
            _ = slow_runs.fetchAdd(1, .monotonic);
            self.process.io.sleep(.fromMilliseconds(ms), .awake) catch return .{ .name = label, .status = .down };
            return .{ .name = label, .status = .up };
        }
    };
}

fn elapsedMs(io: std.Io, since: std.Io.Timestamp) i64 {
    return @intCast(@divTrunc(since.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), std.time.ns_per_ms));
}

test "checks run concurrently" {
    const A = app.App(.{ .modules = &.{}, .adapters = &.{ Slow(300, "a"), Slow(300, "b") } });
    var a: A = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.init(testing.io, testing.allocator, &env);
    defer a.deinit();
    const t0 = std.Io.Clock.awake.now(testing.io);
    var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
    defer res.deinit();
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(elapsedMs(testing.io, t0) < 550);
}

test "a check slower than the timeout is down" {
    const A = app.App(.{ .modules = &.{}, .adapters = &.{ Slow(3000, "slow"), Slow(0, "fast") } });
    var a: A = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.init(testing.io, testing.allocator, &env);
    defer a.deinit();
    const t0 = std.Io.Clock.awake.now(testing.io);
    var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
    defer res.deinit();
    try testing.expectEqual(std.http.Status.service_unavailable, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "{\"name\":\"slow\",\"status\":\"down\"}") != null);
    try testing.expect(std.mem.indexOf(u8, res.body, "{\"name\":\"fast\",\"status\":\"up\"}") != null);
    try testing.expect(elapsedMs(testing.io, t0) < 2600);
}

test "probes within a second share one run" {
    const A = app.App(.{ .modules = &.{}, .adapters = &.{Slow(0, "c")} });
    var a: A = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try a.init(testing.io, testing.allocator, &env);
    defer a.deinit();
    const before = slow_runs.load(.monotonic);
    for (0..3) |_| {
        var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/health/ready" });
        res.deinit();
    }
    try testing.expectEqual(before + 1, slow_runs.load(.monotonic));
}
