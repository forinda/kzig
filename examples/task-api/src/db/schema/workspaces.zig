const db = @import("kzig").db;

pub const workspaces = db.table("workspaces", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .name = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .slug = .{ .type = .{ .varchar = 255 }, .not_null = true, .unique = true },
    .description = .{ .type = .text },
    .ownerId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .logoUrl = .{ .type = .text },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .ownerIdx = .{ .name = "workspaces_owner_idx", .on = .{.ownerId} } },
});
