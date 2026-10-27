const std = @import("std");
const kzig = @import("kzig");
const database = @import("../../db/database.zig");

const Allocator = std.mem.Allocator;
const db = kzig.db;

/// A workspace card: its owner, members with their users, and projects,
/// read in one query (task-kickdb-api's `findFullById`). Users never
/// carry their password hash.
const full = .{
    .owner = .{ .columns = .{ .passwordHash = false } },
    .members = .{ .with = .{ .user = .{ .columns = .{ .passwordHash = false } } } },
    .projects = true,
};
const owned = .{
    .members = .{ .with = .{ .user = .{ .columns = .{ .passwordHash = false } } } },
    .projects = true,
};

const Workspaces = @TypeOf(@as(database.Client, undefined).query(.workspaces));
pub const Workspace = @TypeOf(@as(database.Client, undefined).selectFrom(.workspaces)).Row;
pub const FullWorkspace = Workspaces.Row(.{ .with = full });
pub const OwnedWorkspace = Workspaces.Row(.{ .with = owned });

pub const NewWorkspace = struct {
    name: []const u8,
    slug: []const u8,
    description: ?[]const u8 = null,
    ownerId: []const u8,

    pub fn validate(self: *const NewWorkspace, issues: *kzig.Issues) !void {
        if (self.name.len == 0 or self.name.len > 255) try issues.add("name", "must be 1 to 255 characters");
        if (self.slug.len == 0 or self.slug.len > 255) try issues.add("slug", "must be 1 to 255 characters");
        if (!database.isUuid(self.ownerId)) try issues.add("ownerId", "must be a UUID");
    }
};

/// task-kickdb-api's workspace repository.
pub const WorkspaceRepository = struct {
    database: *database.Database,

    pub fn list(self: *WorkspaceRepository, a: Allocator) ![]Workspace {
        return (try self.database.client()).selectFrom(.workspaces).orderBy(.createdAt, .asc).execute(a);
    }

    pub fn findById(self: *WorkspaceRepository, a: Allocator, id: []const u8) !?Workspace {
        return (try self.database.client()).selectFrom(.workspaces).where(.id, .eq, id).executeTakeFirst(a);
    }

    pub fn findFullById(self: *WorkspaceRepository, a: Allocator, id: []const u8) !?FullWorkspace {
        return (try self.database.client()).query(.workspaces).findUnique(a, .{ .where = db.eq(.id, id), .with = full });
    }

    pub fn listOwnedByUser(self: *WorkspaceRepository, a: Allocator, user_id: []const u8) ![]OwnedWorkspace {
        return (try self.database.client()).query(.workspaces).findMany(a, .{ .where = db.eq(.ownerId, user_id), .orderBy = .createdAt, .with = owned });
    }

    pub fn create(self: *WorkspaceRepository, a: Allocator, in: NewWorkspace) !Workspace {
        return (try self.database.client()).insertInto(.workspaces).values(.{
            .name = in.name,
            .slug = in.slug,
            .description = in.description,
            .ownerId = in.ownerId,
        }).returningAll().executeTakeFirstOrThrow(a);
    }
};
