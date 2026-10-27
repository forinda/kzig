const kzig = @import("kzig");

/// `CRON_DISABLED_JOBS` (comma-separated names to skip), `CRON_SECRET` (the
/// manual run endpoint's bearer; a default only in development and test).
/// `CRON_ENABLED` is kzig's own (`kzig.cron.Settings`).
pub const CronJobSettings = struct {
    pub const prefix = "CRON";
    pub const dev_defaults = .{ .secret = "dev-cron-secret-0123456789" };

    disabled_jobs: []const []const u8 = &.{},
    secret: []const u8,

    pub fn validate(self: *const CronJobSettings, issues: *kzig.Issues) !void {
        if (self.secret.len < 16) try issues.add("secret", "must be at least 16 characters");
    }
};

/// `INVENTORY_SYNC_MS`: how long the simulated supplier call takes.
pub const InventorySettings = struct {
    inventory_sync_ms: u32 = 3000,
};
