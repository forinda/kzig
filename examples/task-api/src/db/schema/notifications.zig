const db = @import("kzig").db;
const enums = @import("enums.zig");

pub const notifications = db.table("notifications", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .recipientId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .type = .{ .type = .{ .@"enum" = enums.NotificationType }, .not_null = true },
    .title = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .body = .{ .type = .text, .not_null = true },
    .metadata = .{ .type = .jsonb, .not_null = true, .default = .{ .value = "'{}'::jsonb" } },
    .isRead = .{ .type = .boolean, .not_null = true, .default = .{ .value = "false" } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .recipientIdx = .{ .name = "notifications_recipient_idx", .on = .{.recipientId} },
        .isReadIdx = .{ .name = "notifications_recipient_read_idx", .on = .{ .recipientId, .isRead } },
    },
});
