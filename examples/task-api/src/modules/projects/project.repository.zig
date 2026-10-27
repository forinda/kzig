const std = @import("std");
const kzig = @import("kzig");
const TenantSchema = @import("../../db/tenant.schema.zig").TenantSchema;
const TenantDatabase = @import("../../db/tenant.database.zig").TenantDatabase;

pub const Project = TenantSchema.Table(.projects).Row;

pub const CreateProject = struct {
    title: []const u8,
    description: ?[]const u8 = null,

    pub fn validate(self: *const CreateProject, issues: *kzig.Issues) !void {
        if (self.title.len < 1 or self.title.len > 200) try issues.add("title", "must be 1 to 200 characters");
        if (self.description) |d| if (d.len > 2000) try issues.add("description", "must be at most 2000 characters");
    }
};

/// No tenant filter of its own in kick/db (its column tenancy adds one);
/// here every query names the workspace.
pub const ProjectRepository = struct {
    database: *TenantDatabase,

    pub fn list(self: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8) ![]const Project {
        const db = try self.database.client();
        return db.selectFrom(.projects).where(.workspaceId, .eq, workspace_id).orderBy(.createdAt, .asc).execute(arena);
    }

    pub fn create(self: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8, input: CreateProject) !Project {
        const db = try self.database.client();
        return db.insertInto(.projects).values(.{ .workspaceId = workspace_id, .title = input.title, .description = input.description }).returningAll().executeTakeFirstOrThrow(arena);
    }

    /// Idempotent by title within the workspace: an existing title is kept,
    /// and every requested row comes back as stored.
    pub fn importMany(self: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8, inputs: []const CreateProject) ![]const Project {
        const db = try self.database.client();
        const out = try arena.alloc(Project, inputs.len);
        for (inputs, out) |input, *slot| slot.* = try db.upsert(arena, .projects, .{ .workspaceId = workspace_id, .title = input.title, .description = input.description }, .{ .target = .{ .workspaceId, .title }, .update = .none });
        return out;
    }
};
