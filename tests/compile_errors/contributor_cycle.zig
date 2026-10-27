const std = @import("std");
const kzig = @import("kzig");
const Ctx = kzig.Ctx;
const LoadA = struct {
    pub const key = "a";
    pub fn resolve(_: *@This(), _: *Ctx, got: struct { b: u32 }) u32 {
        return got.b;
    }
};
const LoadB = struct {
    pub const key = "b";
    pub fn resolve(_: *@This(), _: *Ctx, got: struct { a: u32 }) u32 {
        return got.a;
    }
};
const C = struct {
    pub const contributors = .{ LoadA, LoadB };
    pub const routes = .{.{ .method = .GET, .path = "/", .handler = "h" }};
    pub fn h(_: *@This(), _: *Ctx) void {}
};

const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/x", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
