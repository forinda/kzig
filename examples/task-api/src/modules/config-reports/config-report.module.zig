const kzig = @import("kzig");
const ConfigReportController = @import("config-report.controller.zig").ConfigReportController;

pub const ConfigReportModule = kzig.Module(.{
    .name = "ConfigReportModule",
    .path = "/config",
    .controllers = &.{ConfigReportController},
});
