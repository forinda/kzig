const kzig = @import("kzig");
const LoadAuthUser = @import("../../contributors/auth_user.contributor.zig").LoadAuthUser;
const tenant = @import("../../contributors/tenant.contributor.zig");
const repo = @import("project.repository.zig");

const ImportProjects = struct {
    projects: []const repo.CreateProject,

    pub fn validate(self: *const ImportProjects, issues: *kzig.Issues) !void {
        if (self.projects.len < 1 or self.projects.len > 500) try issues.add("projects", "must have 1 to 500 items");
    }
};

pub const ProjectController = struct {
    projects: *repo.ProjectRepository,

    // Every route runs as the caller's tenant; LoadTenant reads `user`, so
    // LoadAuthUser runs first.
    pub const contributors = .{ tenant.LoadTenant, LoadAuthUser };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list" },
        .{ .method = .POST, .path = "/", .handler = "create" },
        .{ .method = .POST, .path = "/import", .handler = "import" },
    };

    pub fn list(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: tenant.Tenant }) !struct {
        tenant: []const u8,
        projects: []const repo.Project,
    } {
        return .{ .tenant = got.tenant.name, .projects = try self.projects.list(ctx.arena, got.tenant.id) };
    }

    pub fn create(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: tenant.Tenant, body: repo.CreateProject }) !void {
        try ctx.created(try self.projects.create(got.tenant.id, got.body));
    }

    pub fn import(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: tenant.Tenant, body: ImportProjects }) !struct {
        projects: []const repo.Project,
    } {
        return .{ .projects = try self.projects.importMany(ctx.arena, got.tenant.id, got.body.projects) };
    }
};
