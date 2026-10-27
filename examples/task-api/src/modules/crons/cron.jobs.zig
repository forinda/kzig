const std = @import("std");
const kzig = @import("kzig");
const CronService = @import("cron.service.zig").CronService;
const settings = @import("cron.settings.zig");

const log = std.log.scoped(.maintenance_jobs);

/// Stand-in for the supplier's API; tests set `down`.
pub const Supplier = struct {
    process: *const kzig.Process,
    inventory: *const settings.InventorySettings,
    down: bool = false,

    pub fn fetchStock(self: *Supplier) !u32 {
        try self.process.io.sleep(.fromMilliseconds(self.inventory.inventory_sync_ms), .awake);
        if (self.down) return error.SupplierDown;
        return 42;
    }
};

/// cron-jobs-api's four jobs.
pub const MaintenanceJobs = struct {
    cron: *CronService,
    supplier: *Supplier,
    job_settings: *const settings.CronJobSettings,

    pub const crons = .{
        .{ .expression = "*/5 * * * *", .handler = "purgeSessions", .name = "purge-sessions", .description = "Drop expired sessions" },
        .{ .expression = "0 2 * * *", .handler = "nightlyReport", .name = "nightly-report", .description = "Daily sales report at 2am Nairobi time", .timezone = "Africa/Nairobi" },
        .{ .expression = "0 * * * *", .handler = "warmCache", .name = "warm-cache", .description = "Prime the catalogue cache", .run_on_init = true },
        .{ .expression = "*/2 * * * *", .handler = "syncInventory", .name = "sync-inventory", .description = "Pull stock levels from the supplier", .overlap = false },
    };

    /// Checked on every tick: `CRON_DISABLED_JOBS` switches a job off without code.
    pub fn cronEnabled(self: *MaintenanceJobs, name: []const u8) bool {
        for (self.job_settings.disabled_jobs) |d| if (std.mem.eql(u8, d, name)) return false;
        return true;
    }

    pub fn purgeSessions(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.cron.track(run, {}, struct {
            fn work(_: void) !void {
                log.info("Purged expired sessions", .{});
            }
        }.work);
    }

    pub fn nightlyReport(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.cron.track(run, {}, struct {
            fn work(_: void) !void {
                log.info("Nightly report generated", .{});
            }
        }.work);
    }

    pub fn warmCache(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.cron.track(run, run.trigger, struct {
            fn work(trigger: kzig.cron.Trigger) !void {
                log.info("Cache warmed ({t})", .{trigger});
            }
        }.work);
    }

    pub fn syncInventory(self: *MaintenanceJobs, run: kzig.cron.Run) !void {
        try self.cron.track(run, self.supplier, struct {
            fn work(supplier: *Supplier) !void {
                log.info("Synced {d} inventory items", .{try supplier.fetchStock()});
            }
        }.work);
    }
};
