const std = @import("std");
const kzig = @import("kzig");
const database = @import("../../db/database.zig");
const Database = database.Database;

/// The columns responses carry: never the password hash.
const public = .{ .id, .email, .firstName, .lastName, .avatarUrl, .globalRole, .isActive, .createdAt };

pub const User = @TypeOf(@as(database.Client, undefined).selectFrom(.users).select(public)).Row;

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
        if (self.passwordHash.len == 0 or self.passwordHash.len > 255) try issues.add("passwordHash", "must be 1 to 255 characters");
    }
};

/// task-kickdb-api's user repository.
pub const UserRepository = struct {
    database: *Database,

    pub fn list(self: *UserRepository, a: std.mem.Allocator) ![]User {
        return (try self.database.client()).selectFrom(.users).select(public).orderBy(.createdAt, .asc).execute(a);
    }

    pub fn findById(self: *UserRepository, a: std.mem.Allocator, id: []const u8) !?User {
        return (try self.database.client()).selectFrom(.users).select(public).where(.id, .eq, id).executeTakeFirst(a);
    }

    /// A taken email is `error.Conflict` (409), from the unique index.
    pub fn create(self: *UserRepository, a: std.mem.Allocator, in: NewUser) !User {
        return (try self.database.client()).insertInto(.users).values(.{
            .email = in.email,
            .passwordHash = in.passwordHash,
            .firstName = in.firstName,
            .lastName = in.lastName,
            .avatarUrl = in.avatarUrl,
        }).returning(public).executeTakeFirstOrThrow(a);
    }
};
