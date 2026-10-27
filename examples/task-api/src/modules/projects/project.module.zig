const kzig = @import("kzig");
const ProjectController = @import("project.controller.zig").ProjectController;
const ProjectRepository = @import("project.repository.zig").ProjectRepository;
const TenantRepository = @import("../../contributors/tenant.contributor.zig").TenantRepository;
const TokenStore = @import("../../auth.zig").TokenStore;
const tenant_db = @import("../../db/tenant.database.zig");

pub const ProjectModule = kzig.Module(.{
    .name = "ProjectModule",
    .path = "/projects",
    .controllers = &.{ProjectController},
    .services = &.{ ProjectRepository, TenantRepository, TokenStore, tenant_db.TenantDatabase },
    .settings = &.{tenant_db.TenantDbSettings},
});
