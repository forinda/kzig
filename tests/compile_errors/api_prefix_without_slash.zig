const kzig = @import("kzig");
const A = kzig.App(.{ .modules = &.{}, .api_prefix = "api" });
comptime {
    _ = A.routes;
}
