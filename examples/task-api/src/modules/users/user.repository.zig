const std = @import("std");
const kzig = @import("kzig");
const Database = @import("../../db/database.zig").Database;

/// A user as responses carry it: never the password hash.
pub const User = struct {
    id: []const u8,
    email: []const u8,
    firstName: []const u8,
    lastName: []const u8,
    avatarUrl: ?[]const u8,
    globalRole: []const u8,
    isActive: bool,
    createdAt: []const u8,
};

const columns =
    \\"id", "email", "firstName", "lastName", "avatarUrl", "globalRole"::text AS "globalRole", "isActive", "createdAt"::text AS "createdAt"
;

pub const NewUser = struct {
    email: []const u8,
    passwordHash: []const u8,
    firstName: []const u8,
    lastName: []const u8,
    avatarUrl: ?[]const u8 = null,

    pub fn validate(self: *const NewUser, issues: *kzig.Issues) !void {
        if (std.mem.findScalar(u8, self.email, '@') == null or self.email.len > 255) try issues.add("email", "must be an email address");
        if (self.firstName.len == 0 or self.firstName.len > 100) try issues.add("firstName", "must be 1 to 100 characters");
        if (self.lastName.len == 0 or self.lastName.len > 100) try issues.add("lastName", "must be 1 to 100 characters");
    }
};

/// task-kickdb-api's user repository, in SQL.
pub const UserRepository = struct {
    database: *Database,

    pub fn list(self: *UserRepository, a: std.mem.Allocator) ![]User {
        return (try self.database.get()).query(a, User, "SELECT " ++ columns ++ " FROM \"users\" ORDER BY \"createdAt\" ASC", .{});
    }

    pub fn findById(self: *UserRepository, a: std.mem.Allocator, id: []const u8) !?User {
        return (try self.database.get()).queryOne(a, User, "SELECT " ++ columns ++ " FROM \"users\" WHERE \"id\" = $1", .{id});
    }

    /// A taken email is `error.Conflict` (409), from the unique index.
    pub fn create(self: *UserRepository, a: std.mem.Allocator, in: NewUser) !User {
        return (try (try self.database.get()).queryOne(a, User,
            \\INSERT INTO "users" ("email", "passwordHash", "firstName", "lastName", "avatarUrl")
            \\VALUES ($1, $2, $3, $4, $5) RETURNING
        ++ " " ++ columns, .{ in.email, in.passwordHash, in.firstName, in.lastName, in.avatarUrl })).?;
    }
};
