const db = @import("kzig").db;

pub const task_assignees = db.table("task_assignees", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .taskId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "tasks.id", .on_delete = .cascade } },
    .userId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .assignedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .pairUnique = .{ .name = "task_assignees_task_user_unique", .on = .{ .taskId, .userId }, .unique = true } },
});
