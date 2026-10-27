const std = @import("std");
const kzig = @import("kzig");

pub const Project = struct {
    id: []const u8,
    workspaceId: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
};

pub const CreateProject = struct {
    title: []const u8,
    description: ?[]const u8 = null,

    pub fn validate(self: *const CreateProject, issues: *kzig.Issues) !void {
        if (self.title.len < 1 or self.title.len > 200) try issues.add("title", "must be 1 to 200 characters");
        if (self.description) |d| if (d.len > 2000) try issues.add("description", "must be at most 2000 characters");
    }
};

/// In memory, shared by concurrent requests, so every access holds the lock.
/// Every query is scoped to one workspace.
pub const ProjectRepository = struct {
    process: *const kzig.Process,
    mutex: std.Io.Mutex = .init,
    rows: std.ArrayList(Project) = .empty,
    /// Owns the rows' strings for the app's lifetime.
    strings: std.heap.ArenaAllocator = undefined,

    pub fn init(self: *ProjectRepository) void {
        self.strings = .init(self.process.gpa);
    }

    pub fn deinit(self: *ProjectRepository) void {
        self.rows.deinit(self.process.gpa);
        self.strings.deinit();
    }

    pub fn list(self: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8) ![]const Project {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        var out: std.ArrayList(Project) = .empty;
        for (self.rows.items) |p| if (std.mem.eql(u8, p.workspaceId, workspace_id)) try out.append(arena, p);
        return out.items;
    }

    pub fn create(self: *ProjectRepository, workspace_id: []const u8, input: CreateProject) !Project {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        return self.insert(workspace_id, input);
    }

    /// Idempotent by title within the workspace: an existing title is kept,
    /// and every requested row comes back.
    pub fn importMany(self: *ProjectRepository, arena: std.mem.Allocator, workspace_id: []const u8, inputs: []const CreateProject) ![]const Project {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        const out = try arena.alloc(Project, inputs.len);
        for (inputs, out) |input, *slot| slot.* = self.find(workspace_id, input.title) orelse try self.insert(workspace_id, input);
        return out;
    }

    fn find(self: *ProjectRepository, workspace_id: []const u8, title: []const u8) ?Project {
        for (self.rows.items) |p| if (std.mem.eql(u8, p.workspaceId, workspace_id) and std.mem.eql(u8, p.title, title)) return p;
        return null;
    }

    fn insert(self: *ProjectRepository, workspace_id: []const u8, input: CreateProject) !Project {
        const a = self.strings.allocator();
        const p: Project = .{
            .id = try std.fmt.allocPrint(a, "p-{d}", .{self.rows.items.len + 1}),
            .workspaceId = try a.dupe(u8, workspace_id),
            .title = try a.dupe(u8, input.title),
            .description = if (input.description) |d| try a.dupe(u8, d) else null,
        };
        try self.rows.append(self.process.gpa, p);
        return p;
    }
};
