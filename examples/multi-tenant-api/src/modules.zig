const ProjectModule = @import("modules/projects/project.module.zig").ProjectModule;

/// Every module the app mounts.
pub const modules: []const type = &.{ProjectModule};
