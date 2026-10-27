const std = @import("std");
const AppSettings = @import("../../config/app.settings.zig").AppSettings;
const FeatureSettings = @import("feature.settings.zig").FeatureSettings;

pub const FeaturesService = struct {
    features: *const FeatureSettings,
    app: *const AppSettings,

    pub const Current = struct {
        app: []const u8,
        signupUrl: ?[]const u8,
        betaBanner: bool,
        maxUploadBytes: u64,
    };

    pub fn current(self: *FeaturesService, arena: std.mem.Allocator) !Current {
        const f = self.features;
        return .{
            .app = self.app.name,
            .signupUrl = if (f.signups) try arena.print("{s}/signup", .{std.mem.trimEnd(u8, self.app.public_url, "/")}) else null,
            .betaBanner = f.beta_banner,
            .maxUploadBytes = @as(u64, f.max_upload_mb) * 1024 * 1024,
        };
    }

    /// For code that already knows the user; never answered for an email a
    /// caller sends, which would reveal who is on the list.
    pub fn isBetaTester(self: *FeaturesService, email: []const u8) bool {
        for (self.features.beta_testers) |t| if (std.ascii.eqlIgnoreCase(t, email)) return true;
        return false;
    }
};
