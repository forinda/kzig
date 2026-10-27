const kzig = @import("kzig");
const database = @import("../db/database.zig");

/// task-kickdb-api's `DbAdapter` with `kickDbAdapter()`'s boot rule:
/// migrations are applied on boot in development and test, and anywhere
/// else a pending one stops the boot. `postgres` on `/health/ready`.
pub const DbAdapter = struct {
    /// What `kzig db generate --db postgres` writes migrations for.
    pub const db_name = "postgres";
    pub const db_schema = @import("../db/schema.zig").Schema;

    database: *database.Database,
    settings: *const database.DbSettings,
    process: *const kzig.Process,

    pub fn beforeStart(self: *DbAdapter) !void {
        const pool = self.database.get() catch return;
        try kzig.db.migrate.onBoot(pool, self.process.io, self.process.gpa, self.settings.migrations_dir, .{
            .on_boot = if (self.process.dev_or_test) .apply else .fail_if_pending,
        });
    }

    /// No database configured: nothing to report.
    pub fn onHealthCheck(self: *DbAdapter) ?kzig.HealthCheck {
        const pool = self.database.get() catch return null;
        pool.ping() catch return .{ .name = "postgres", .status = .down };
        return .{ .name = "postgres", .status = .up };
    }
};
