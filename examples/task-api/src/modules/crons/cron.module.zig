const kzig = @import("kzig");
const CronController = @import("cron.controller.zig").CronController;
const CronService = @import("cron.service.zig").CronService;
const jobs = @import("cron.jobs.zig");
const settings = @import("cron.settings.zig");
const Clock = @import("../../clock.zig").Clock;

/// cron-jobs-api: the jobs, and /api/v1/cron to list and run them.
pub const CronModule = kzig.Module(.{
    .name = "CronModule",
    .path = "/cron",
    .controllers = &.{CronController},
    .services = &.{ CronService, jobs.MaintenanceJobs, jobs.Supplier, Clock },
    .settings = &.{ settings.CronJobSettings, settings.InventorySettings },
});
