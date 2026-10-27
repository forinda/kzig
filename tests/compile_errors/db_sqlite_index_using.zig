const kzig = @import("kzig");
const t = kzig.db.table("t", .{ .a = .{ .type = .text } }, .{ .indexes = .{ .n = .{ .name = "t_a", .on = .{.a}, .using = "gin" } } });
comptime {
    _ = kzig.db.Schema(.{ .t = t }, .{ .dialect = .sqlite }).tables_info;
}
