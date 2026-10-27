const kzig = @import("kzig");
const tasks = kzig.db.table("tasks", .{
    .id = .{ .type = .serial, .primary_key = true },
    .projectId = .{ .type = .uuid, .references = .{ .to = "nope.id" } },
}, .{});
comptime {
    _ = kzig.db.Schema(.{ .tasks = tasks }, .{}).tables_info;
}
