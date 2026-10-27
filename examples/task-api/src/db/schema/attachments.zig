const db = @import("kzig").db;

pub const attachments = db.table("attachments", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .taskId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "tasks.id", .on_delete = .cascade } },
    .uploaderId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    .fileName = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .fileSize = .{ .type = .integer, .not_null = true },
    .mimeType = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .data = .{ .type = .text, .not_null = true },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .taskIdx = .{ .name = "attachments_task_idx", .on = .{.taskId} } },
});
