const kzig = @import("kzig");
/// Every config variable, who declared it, whether it's required and where
/// its value came from. Names only — no values. Development and test only.
pub const ConfigReportController = struct {
    origins: *const kzig.ConfigReport,
    process: *const kzig.Process,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "report" },
    };

    pub fn report(self: *ConfigReportController, _: *kzig.Ctx) !struct { vars: []const kzig.config.Origin } {
        // Not `Config.node_env`: it defaults to development, so an unset
        // NODE_ENV would serve the report.
        if (!self.process.dev_or_test) return error.NotFound;
        return .{ .vars = self.origins.vars };
    }
};
