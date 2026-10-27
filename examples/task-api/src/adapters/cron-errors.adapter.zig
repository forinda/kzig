const std = @import("std");
const builtin = @import("builtin");
const kzig = @import("kzig");

/// A failing job, reported (cron-jobs-api's `CronErrorsAdapter`). Swap the
/// log line for Sentry or Datadog.
pub const CronErrorsAdapter = struct {
    count: u32 = 0,
    last: ?kzig.cron.ErrorInfo = null,

    pub fn onCronError(self: *CronErrorsAdapter, err: anyerror, info: kzig.cron.ErrorInfo) void {
        self.count += 1;
        self.last = info;
        if (!builtin.is_test) std.log.err("cron job {s} ({s}, {t}) failed: {t}", .{ info.job, info.expression, info.trigger, err });
    }
};
