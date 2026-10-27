const kzig = @import("kzig");
const Service = struct { n: u32 = 1 };
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .services = &.{Service} })} });
export fn entry() void {
    var app: A = undefined;
    app.initWith(undefined, undefined, undefined, .{Service{ .n = 2 }}) catch {};
}
