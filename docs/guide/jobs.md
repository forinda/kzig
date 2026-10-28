# Scheduled jobs

KickJS's `@Cron`: any service lists its jobs, and the App schedules them once it is listening.

```zig
pub const MaintenanceJobs = struct {
    reports: *ReportService,

    pub const crons = .{
        .{ .expression = "*/5 * * * *", .handler = "purge", .name = "purge-sessions" },
        .{ .expression = "0 2 * * *", .handler = "nightly", .timezone = "Africa/Nairobi" },
        .{ .expression = "0 * * * *", .handler = "warm", .run_on_init = true },
    };

    /// Asked on every tick and manual run.
    pub fn cronEnabled(self: *MaintenanceJobs, name: []const u8) bool { … }

    pub fn nightly(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.reports.generate(run.arena);
    }
};
```

Expressions have 5 fields or 6 (seconds first), with names, ranges, steps and lists; a bad one
fails `zig build`. Timezones come from the system's zoneinfo (`CRON_ZONEINFO`). A run while the
previous is still going is skipped unless `.overlap = true`. Across a daylight-saving change, a
local time that doesn't exist is skipped, and in a repeated hour only jobs with `*` hours run
again. `CRON_ENABLED=false` schedules
nothing (one replica of several, say). Inject `*kzig.cron.Jobs` to list jobs, get their next run
or run one now; a failure reaches adapters' `onCronError(err, info)`. Shutdown stops the
schedule and waits for runs in flight. task-api's `crons` module is the archive's
cron-jobs-api.
