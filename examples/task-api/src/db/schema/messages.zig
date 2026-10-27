const db = @import("kzig").db;

pub const messages = db.table("messages", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .channelId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "channels.id", .on_delete = .cascade } },
    .senderId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    .content = .{ .type = .text, .not_null = true },
    .mentions = .{ .type = .jsonb, .not_null = true, .default = .{ .value = "'[]'::jsonb" } },
    .isEdited = .{ .type = .boolean, .not_null = true, .default = .{ .value = "false" } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .channelIdx = .{ .name = "messages_channel_idx", .on = .{.channelId} },
        .senderIdx = .{ .name = "messages_sender_idx", .on = .{.senderId} },
    },
});
