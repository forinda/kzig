const kzig = @import("kzig");
const FeaturesController = @import("feature.controller.zig").FeaturesController;
const FeaturesService = @import("feature.service.zig").FeaturesService;
const FeatureSettings = @import("feature.settings.zig").FeatureSettings;

pub const FeaturesModule = kzig.Module(.{
    .name = "FeaturesModule",
    .path = "/features",
    .controllers = &.{FeaturesController},
    .services = &.{FeaturesService},
    // Validated at boot and injectable — only because this module is mounted.
    .settings = &.{FeatureSettings},
});
