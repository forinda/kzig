const kzig = @import("kzig");
const C1 = struct {
    pub const routes = .{.{ .method = .GET, .path = "/:id", .handler = "show" }};
    pub fn show(_: *@This(), _: *kzig.Ctx) void {}
};
const C2 = struct {
    pub const routes = .{.{ .method = .GET, .path = "/:key", .handler = "find" }};
    pub fn find(_: *@This(), _: *kzig.Ctx) void {}
};
const A = kzig.App(.{ .modules = &.{
    kzig.Module(.{ .name = "M1", .path = "/x", .controllers = &.{C1} }),
    kzig.Module(.{ .name = "M2", .path = "/x", .controllers = &.{C2} }),
} });
comptime {
    _ = A.routes;
}
