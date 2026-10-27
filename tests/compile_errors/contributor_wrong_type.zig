const std = @import("std");
const kzig = @import("kzig");
const Ctx = kzig.Ctx;
const LoadA = struct {
    pub const key = "a";
    pub fn resolve(_: *@This(), _: *Ctx) u32 {
        return 1;
    }
};
const C = struct {
    pub const contributors = .{LoadA};
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "h" }};
    pub fn h(_: *@This(), _: *Ctx, got: struct { a: []const u8 }) []const u8 {
        return got.a;
    }
};

const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/x", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
