const std = @import("std");
const kzig = @import("kzig");
const Clock = @import("../../clock.zig").Clock;
const iso = @import("../../clock.zig").iso;

pub const LastRun = struct {
    at: i64,
    trigger: kzig.cron.Trigger,
    status: enum { running, ok, failed },
    duration_ms: ?i64 = null,
    err: ?anyerror = null,
};

/// Each job's last run, and the job list with next runs. In memory, per
/// process (cron-jobs-api's `CronService`).
pub const CronService = struct {
    process: *const kzig.Process,
    jobs: *kzig.cron.Jobs,
    clock: *Clock,
    mutex: std.Io.Mutex = .init,
    /// By the App's job index.
    last: []?LastRun = &.{},

    pub fn init(self: *CronService) !void {
        self.last = try self.process.gpa.alloc(?LastRun, self.jobs.list().len);
        @memset(self.last, null);
    }

    pub fn deinit(self: *CronService) void {
        self.process.gpa.free(self.last);
    }

    /// Records `work`'s run under `run.name`; its error is kept and passed on.
    pub fn track(self: *CronService, run: kzig.cron.Run, ctx: anytype, comptime work: anytype) !void {
        const i = self.jobs.find(run.name).?;
        const started = nowMs(self.process.io);
        self.set(i, .{ .at = run.fired_at, .trigger = run.trigger, .status = .running });
        work(ctx) catch |err| {
            self.set(i, .{ .at = run.fired_at, .trigger = run.trigger, .status = .failed, .duration_ms = nowMs(self.process.io) - started, .err = err });
            return err;
        };
        self.set(i, .{ .at = run.fired_at, .trigger = run.trigger, .status = .ok, .duration_ms = nowMs(self.process.io) - started });
    }

    fn set(self: *CronService, i: usize, v: LastRun) void {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        self.last[i] = v;
    }

    pub const Listed = struct {
        name: []const u8,
        description: ?[]const u8,
        expression: []const u8,
        timezone: ?[]const u8,
        enabled: bool,
        lastRun: ?struct { at: []const u8, trigger: kzig.cron.Trigger, status: []const u8, durationMs: ?i64, @"error": ?[]const u8 },
        nextRun: ?[]const u8,
    };

    pub fn list(self: *CronService, arena: std.mem.Allocator) ![]const Listed {
        const now = self.clock.now();
        const infos = self.jobs.list();
        const out = try arena.alloc(Listed, infos.len);
        for (infos, out, 0..) |info, *o, i| {
            const enabled = self.jobs.enabled(i);
            self.mutex.lockUncancelable(self.process.io);
            const last = self.last[i];
            self.mutex.unlock(self.process.io);
            o.* = .{
                .name = info.name,
                .description = info.description,
                .expression = info.expression,
                .timezone = info.timezone,
                .enabled = enabled,
                .lastRun = if (last) |l| .{
                    .at = try iso(arena, l.at),
                    .trigger = l.trigger,
                    .status = @tagName(l.status),
                    .durationMs = l.duration_ms,
                    .@"error" = if (l.err) |e| @errorName(e) else null,
                } else null,
                .nextRun = if (!enabled) null else if (self.jobs.next(i, now)) |t| try iso(arena, t) else null,
            };
        }
        return out;
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).toNanoseconds(), std.time.ns_per_ms));
}
