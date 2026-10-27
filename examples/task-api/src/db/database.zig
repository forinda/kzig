const std = @import("std");
const kzig = @import("kzig");
const Schema = @import("schema.zig").Schema;

pub const Client = kzig.db.Client(Schema);

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

    /// The query builder over task-kickdb-api's schema (`DB_PRIMARY`).
    pub fn client(self: *Database) !Client {
        return .init(.{ .pool = try self.get() });
    }
};

/// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`: checked before a query, so a bad id
/// is no such row (or a 422), not a database error.
pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (if (dash) c != '-' else !std.ascii.isHex(c)) return false;
    }
    return true;
}
