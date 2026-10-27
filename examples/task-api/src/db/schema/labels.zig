const db = @import("kzig").db;

pub const labels = db.table("labels", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .name = .{ .type = .{ .varchar = 100 }, .not_null = true },
    // #RRGGBB
    .color = .{ .type = .{ .char = 7 }, .not_null = true },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .nameUnique = .{ .name = "labels_workspace_name_unique", .on = .{ .workspaceId, .name }, .unique = true } },
});
