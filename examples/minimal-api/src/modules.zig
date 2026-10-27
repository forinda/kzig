const HelloModule = @import("modules/hello/hello.module.zig").HelloModule;

/// Every module the app mounts.
pub const modules: []const type = &.{HelloModule};
