const kzig = @import("kzig");
const t = kzig.db.table("t", .{ .a = .{ .type = .text } }, .{ .indexes = .{ .n = .{ .name = "t_a", .on = .{.a}, .uniqe = true } } });
comptime {
    _ = kzig.db.Schema(.{ .t = t }, .{}).tables_info;
}
