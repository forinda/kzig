const kzig = @import("kzig");
const A1 = struct { b: *B1 };
const B1 = struct { a: *A1 };
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .services = &.{ A1, B1 } })} });
export fn entry() void {
    var app: A = undefined;
    app.init(undefined, undefined, undefined) catch {};
}
