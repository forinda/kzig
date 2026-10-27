const db = @import("kzig").db;

pub const task_labels = db.table("task_labels", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .taskId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "tasks.id", .on_delete = .cascade } },
    .labelId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "labels.id", .on_delete = .cascade } },
    .appliedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .pairUnique = .{ .name = "task_labels_task_label_unique", .on = .{ .taskId, .labelId }, .unique = true } },
});
