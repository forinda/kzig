const kzig = @import("kzig");
const t = kzig.db.table("t", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const S = kzig.db.Schema(.{ .t = t }, .{});
const A1 = struct {
    pub const db_name = "main";
    pub const db_schema = S;
};
const A2 = struct {
    pub const db_name = "main";
    pub const db_schema = S;
};
const A = kzig.App(.{ .modules = &.{}, .adapters = &.{ A1, A2 } });
comptime {
    _ = A.schemas;
}
