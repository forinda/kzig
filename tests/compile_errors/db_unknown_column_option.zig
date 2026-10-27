const kzig = @import("kzig");
const users = kzig.db.table("users", .{
    .email = .{ .type = .text, .notNull = true },
}, .{});
comptime {
    _ = users.Row;
}
