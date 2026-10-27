const kzig = @import("kzig");
const LoadAuthUser = @import("../../contributors/auth_user.contributor.zig").LoadAuthUser;
const tenant = @import("../../contributors/tenant.contributor.zig");
const repo = @import("project.repository.zig");

pub const ProjectController = struct {
    projects: *repo.ProjectRepository,

    // Every route runs as the caller's tenant; LoadTenant reads `user`, so
    // LoadAuthUser runs first.
    pub const contributors = .{ tenant.LoadTenant, LoadAuthUser };

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list" },
    };

    pub fn list(self: *ProjectController, ctx: *kzig.Ctx, got: struct { tenant: tenant.Tenant }) !struct {
        tenant: []const u8,
        projects: []const repo.Project,
    } {
        return .{ .tenant = got.tenant.name, .projects = try self.projects.list(ctx.arena, got.tenant.id) };
    }
};
