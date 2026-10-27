const std = @import("std");

pub const Project = struct { id: []const u8, workspaceId: []const u8, title: []const u8 };

/// In memory and read-only; every query is scoped to one workspace.
pub const ProjectRepository = struct {
    const rows = [_]Project{
        .{ .id = "p-1", .workspaceId = "tenant-acme", .title = "Rocket skates" },
    };

    pub fn list(_: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8) ![]const Project {
        var out: std.ArrayList(Project) = .empty;
        for (rows) |p| if (std.mem.eql(u8, p.workspaceId, workspace_id)) try out.append(arena, p);
        return out.items;
    }
};
