const std = @import("std");
const kzig = @import("kzig");
const Ctx = kzig.Ctx;
fn Load(comptime v: u32) type {
    return struct {
        pub const key = "a";
        pub fn resolve(_: *@This(), _: *Ctx) u32 {
            return v;
        }
    };
}
const C = struct {
    pub const contributors = .{ Load(1), Load(2) };
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "h" }};
    pub fn h(_: *@This(), _: *Ctx) void {}
};

const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/x", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
