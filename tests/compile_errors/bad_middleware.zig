const std = @import("std");
const kzig = @import("kzig");
const Ctx = kzig.Ctx;
const C = struct {
    pub const middleware = .{42};
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "h" }};
    pub fn h(_: *@This(), _: *Ctx) void {}
};

const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/x", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
