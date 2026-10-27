const std = @import("std");
const kzig = @import("kzig");
const TenantSchema = @import("tenant.schema.zig").TenantSchema;

pub const Client = kzig.db.Client(TenantSchema);

pub const TenantDbSettings = struct {
    /// The SQLite file; `:memory:` for a throwaway database (tests).
    db_file: []const u8 = "data/app.db",
    sqlite_migrations_dir: []const u8 = "db/sqlite-migrations",
};

/// multi-tenant-kickdb-api's `db/client.ts`: one SQLite handle for the app.
/// A build without `-Dsqlite` has none, and the routes on it answer 503.
pub const TenantDatabase = struct {
    process: *const kzig.Process,
    settings: *const TenantDbSettings,
    pool: ?kzig.db.Pool = null,

    pub fn init(self: *TenantDatabase) !void {
        if (!kzig.db.sqlite_built) return;
        const file = self.settings.db_file;
        if (!std.mem.eql(u8, file, ":memory:")) if (std.fs.path.dirname(file)) |dir|
            try std.Io.Dir.cwd().createDirPath(self.process.io, dir);
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        self.pool = try .init(self.process.io, self.process.gpa, .{ .url = try std.fmt.bufPrint(&buf, "sqlite:{s}", .{file}) });
    }

    pub fn deinit(self: *TenantDatabase) void {
        if (self.pool) |*p| p.deinit();
    }

    pub fn get(self: *TenantDatabase) !*kzig.db.Pool {
        if (self.pool) |*p| return p;
        return error.ServiceUnavailable;
    }

    pub fn client(self: *TenantDatabase) !Client {
        return .init(.{ .pool = try self.get() });
    }
};
