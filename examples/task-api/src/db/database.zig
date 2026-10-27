const kzig = @import("kzig");

/// `MIGRATIONS_DIR`, relative to the working directory.
pub const DbSettings = struct {
    migrations_dir: []const u8 = "db/migrations",
};

/// task-kickdb-api's `db/client.ts`: one pool for the app, made when
/// `DATABASE_URL` is set. Without it the rest of task-api still runs and the
/// database routes answer 503.
pub const Database = struct {
    process: *const kzig.Process,
    settings: *const kzig.db.Settings,
    pool: ?kzig.db.Pool = null,

    /// Connects lazily: nothing is opened until the first query.
    pub fn init(self: *Database) !void {
        const url = self.settings.database_url orelse return;
        self.pool = try .init(self.process.io, self.process.gpa, .{ .url = url });
    }

    pub fn deinit(self: *Database) void {
        if (self.pool) |*p| p.deinit();
    }

    pub fn get(self: *Database) !*kzig.db.Pool {
        if (self.pool) |*p| return p;
        return error.ServiceUnavailable;
    }
};
