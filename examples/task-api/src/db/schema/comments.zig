const db = @import("kzig").db;

pub const comments = db.table("comments", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .taskId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "tasks.id", .on_delete = .cascade } },
    .authorId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    .content = .{ .type = .text, .not_null = true },
    .mentions = .{ .type = .jsonb, .not_null = true, .default = .{ .value = "'[]'::jsonb" } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .taskIdx = .{ .name = "comments_task_idx", .on = .{.taskId} },
        .authorIdx = .{ .name = "comments_author_idx", .on = .{.authorId} },
    },
});
