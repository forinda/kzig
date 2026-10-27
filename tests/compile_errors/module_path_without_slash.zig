const kzig = @import("kzig");
const C = struct {
    pub const routes = .{.{ .method = .GET, .path = "/x", .handler = "x" }};
    pub fn x(_: *@This(), _: *kzig.Ctx) void {}
};
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "hello", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
