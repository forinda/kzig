const kzig = @import("kzig");
const users = kzig.db.table("users", .{
    .firstName = .{ .type = .text },
}, .{ .indexes = .{ .nameIdx = .{ .name = "users_name_idx", .on = .{.fullName} } } });
comptime {
    _ = users.Row;
}
