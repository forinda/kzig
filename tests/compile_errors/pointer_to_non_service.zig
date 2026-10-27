const std = @import("std");
const kzig = @import("kzig");
const Service = struct { alloc: *std.mem.Allocator };
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .services = &.{Service} })} });
export fn entry() void {
    var app: A = undefined;
    app.init(undefined, undefined, undefined) catch {};
}
