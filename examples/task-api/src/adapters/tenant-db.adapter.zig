const kzig = @import("kzig");
const database = @import("../db/tenant.database.zig");

/// multi-tenant-kickdb-api's `DbAdapter`: its migrations on boot (development
/// and test; elsewhere a pending one stops the boot), `sqlite` on
/// `/health/ready`.
pub const TenantDbAdapter = struct {
    /// What `kzig db generate --db sqlite` writes migrations for.
    pub const db_name = "sqlite";
    pub const db_schema = @import("../db/tenant.schema.zig").TenantSchema;

    database: *database.TenantDatabase,
    settings: *const database.TenantDbSettings,
    process: *const kzig.Process,

    pub fn beforeStart(self: *TenantDbAdapter) !void {
        const pool = self.database.get() catch return;
        try kzig.db.migrate.onBoot(pool, self.process.io, self.process.gpa, self.settings.sqlite_migrations_dir, .{
            .on_boot = if (self.process.dev_or_test) .apply else .fail_if_pending,
        });
    }

    pub fn onHealthCheck(self: *TenantDbAdapter) ?kzig.HealthCheck {
        const pool = self.database.get() catch return null;
        pool.ping() catch return .{ .name = "sqlite", .status = .down };
        return .{ .name = "sqlite", .status = .up };
    }
};
