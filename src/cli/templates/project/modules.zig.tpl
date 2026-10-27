//! Every module the app mounts. `kzig g module <name>` adds a line here;
//! `kzig rm module <name>` takes it out.
pub const modules: []const type = &.{
    @import("modules/hello/hello.module.zig").HelloModule,
    // kzig:modules
};
