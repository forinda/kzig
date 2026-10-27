const kzig = @import("kzig");
const t = kzig.db.table("t", .{ .a = .{ .type = .integer } }, .{ .check = .{ .pos = .{ .name = "t_pos", .sql = "a > 0" } } });
comptime {
    _ = t.Row;
}
