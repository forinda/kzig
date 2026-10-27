const kzig = @import("kzig");
const repo = @import("workspace.repository.zig");
const database = @import("../../db/database.zig");

const Id = struct {
    id: []const u8,

    /// Not a UUID: no such workspace, rather than a database error.
    pub fn validate(self: *const Id, issues: *kzig.Issues) !void {
        if (!database.isUuid(self.id)) try issues.add("id", "must be a UUID");
    }
};

const UserId = struct {
    userId: []const u8,

    pub fn validate(self: *const UserId, issues: *kzig.Issues) !void {
        if (!database.isUuid(self.userId)) try issues.add("userId", "must be a UUID");
    }
};

pub const WorkspaceController = struct {
    workspaces: *repo.WorkspaceRepository,

    pub const docs = .{ .tags = &[_][]const u8{"Workspaces"} };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list", .docs = .{ .summary = "List workspaces" } },
        .{ .method = .GET, .path = "/owned-by/:userId", .handler = "ownedBy", .docs = .{ .summary = "Workspaces a user owns, with members and projects" } },
        .{ .method = .GET, .path = "/:id", .handler = "show", .docs = .{
            .summary = "Get a workspace",
            .responses = .{ .{ .status = 200, .description = "The workspace", .body = repo.Workspace }, .{ .status = 404, .description = "No such workspace" } },
        } },
        .{ .method = .GET, .path = "/:id/full", .handler = "showFull", .docs = .{
            .summary = "A workspace with its owner, members and projects, in one query",
            .responses = .{ .{ .status = 200, .description = "The workspace", .body = repo.FullWorkspace }, .{ .status = 404, .description = "No such workspace" } },
        } },
        .{ .method = .POST, .path = "/", .handler = "create", .docs = .{
            .summary = "Create a workspace",
            .responses = .{ .{ .status = 201, .description = "Created", .body = repo.Workspace }, .{ .status = 409, .description = "Slug taken" } },
        } },
    };

    pub fn list(self: *WorkspaceController, ctx: *kzig.Ctx) !struct { workspaces: []const repo.Workspace } {
        return .{ .workspaces = try self.workspaces.list(ctx.arena) };
    }

    pub fn show(self: *WorkspaceController, ctx: *kzig.Ctx, got: struct { params: Id }) !repo.Workspace {
        return try self.workspaces.findById(ctx.arena, got.params.id) orelse ctx.fail(.not_found, null);
    }

    pub fn showFull(self: *WorkspaceController, ctx: *kzig.Ctx, got: struct { params: Id }) !repo.FullWorkspace {
        return try self.workspaces.findFullById(ctx.arena, got.params.id) orelse ctx.fail(.not_found, null);
    }

    pub fn ownedBy(self: *WorkspaceController, ctx: *kzig.Ctx, got: struct { params: UserId }) !struct { workspaces: []const repo.OwnedWorkspace } {
        return .{ .workspaces = try self.workspaces.listOwnedByUser(ctx.arena, got.params.userId) };
    }

    pub fn create(self: *WorkspaceController, ctx: *kzig.Ctx, got: struct { body: repo.NewWorkspace }) !void {
        try ctx.created(try self.workspaces.create(ctx.arena, got.body));
    }
};
