const HelloModule = @import("modules/hello/hello.module.zig").HelloModule;
const ProjectModule = @import("modules/projects/project.module.zig").ProjectModule;
const FeaturesModule = @import("modules/features/feature.module.zig").FeaturesModule;
const ConfigReportModule = @import("modules/config-reports/config-report.module.zig").ConfigReportModule;

/// Every module the app mounts.
pub const modules: []const type = &.{ HelloModule, ProjectModule, FeaturesModule, ConfigReportModule };
