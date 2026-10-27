//! Every module the app mounts. `kzig g module <name>` adds a line here;
//! `kzig rm module <name>` takes it out.
pub const modules: []const type = &.{
    @import("modules/hello/hello.module.zig").HelloModule,
    @import("modules/projects/project.module.zig").ProjectModule,
    @import("modules/features/feature.module.zig").FeaturesModule,
    @import("modules/config-reports/config-report.module.zig").ConfigReportModule,
    @import("modules/tasks/task.module.zig").TaskModule,
    @import("modules/files/file.module.zig").FilesModule,
    @import("modules/chats/chat.module.zig").ChatModule,
    @import("modules/crons/cron.module.zig").CronModule,
    // kzig:modules
};
