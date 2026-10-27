const kzig = @import("kzig");
const FeaturesService = @import("feature.service.zig").FeaturesService;

pub const FeaturesController = struct {
    features: *FeaturesService,

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "get" },
    };

    pub fn get(self: *FeaturesController, ctx: *kzig.Ctx) !FeaturesService.Current {
        return self.features.current(ctx.arena);
    }
};
