const kzig = @import("kzig");
const Db = struct {};
const Cache = struct {
    pub const depends_on = .{Db};
};
const A = kzig.App(.{ .modules = &.{}, .adapters = &.{Cache} });
comptime {
    _ = A.routes;
}
