const kzig = @import("kzig");
const ProjectController = @import("project.controller.zig").ProjectController;
const ProjectRepository = @import("project.repository.zig").ProjectRepository;
const TenantRepository = @import("../../contributors/tenant.contributor.zig").TenantRepository;
const TokenStore = @import("../../auth.zig").TokenStore;

pub const ProjectModule = kzig.Module(.{
    .name = "ProjectModule",
    .path = "/projects",
    .controllers = &.{ProjectController},
    .services = &.{ ProjectRepository, TenantRepository, TokenStore },
});
