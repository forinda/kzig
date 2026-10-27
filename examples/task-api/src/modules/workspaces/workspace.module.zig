const kzig = @import("kzig");
const WorkspaceController = @import("workspace.controller.zig").WorkspaceController;
const WorkspaceRepository = @import("workspace.repository.zig").WorkspaceRepository;
const db = @import("../../db/database.zig");

/// task-kickdb-api's workspaces, on Postgres, with relational reads.
pub const WorkspaceModule = kzig.Module(.{
    .name = "WorkspaceModule",
    .path = "/workspaces",
    .controllers = &.{WorkspaceController},
    .services = &.{ WorkspaceRepository, db.Database },
    .settings = &.{ kzig.db.Settings, db.DbSettings },
});
