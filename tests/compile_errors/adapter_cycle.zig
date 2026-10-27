const kzig = @import("kzig");
const A1 = struct {
    pub const depends_on = .{B1};
};
const B1 = struct {
    pub const depends_on = .{A1};
};
const A = kzig.App(.{ .modules = &.{}, .adapters = &.{ A1, B1 } });
comptime {
    _ = A.routes;
}
