const db = @import("kzig").db;

pub const channel_members = db.table("channel_members", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .channelId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "channels.id", .on_delete = .cascade } },
    .userId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .joinedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .pairUnique = .{ .name = "channel_members_channel_user_unique", .on = .{ .channelId, .userId }, .unique = true } },
});
