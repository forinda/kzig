const db = @import("kzig").db;

pub const refresh_tokens = db.table("refresh_tokens", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .userId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .token = .{ .type = .{ .varchar = 255 }, .not_null = true, .unique = true },
    .expiresAt = .{ .type = .timestamp, .not_null = true },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .userIdx = .{ .name = "refresh_tokens_user_idx", .on = .{.userId} } },
});
