const kzig = @import("kzig");
const Config = @import("../../config/config.zig").Config;

/// Every config variable, who declared it, whether it's required and where
/// its value came from. Names only — no values. Outside production only.
pub const ConfigReportController = struct {
    origins: *const kzig.ConfigReport,
    config: *const Config,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "report" },
    };

    pub fn report(self: *ConfigReportController, _: *kzig.Ctx) !struct { vars: []const kzig.config.Origin } {
        if (self.config.node_env == .production) return error.NotFound;
        return .{ .vars = self.origins.vars };
    }
};
