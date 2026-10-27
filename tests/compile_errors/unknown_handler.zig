const kzig = @import("kzig");
const C = struct {
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "lst" }};
    pub fn list(_: *@This(), _: *kzig.Ctx) void {}
};
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/x", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
