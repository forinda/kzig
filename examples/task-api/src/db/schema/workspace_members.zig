const db = @import("kzig").db;
const enums = @import("enums.zig");

pub const workspace_members = db.table("workspace_members", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .userId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id", .on_delete = .cascade } },
    .role = .{ .type = .{ .@"enum" = enums.WorkspaceRole }, .not_null = true, .default = .{ .value = "member" } },
    .joinedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .pairUnique = .{ .name = "workspace_members_workspace_user_unique", .on = .{ .workspaceId, .userId }, .unique = true },
        .workspaceIdx = .{ .name = "workspace_members_workspace_idx", .on = .{.workspaceId} },
        .userIdx = .{ .name = "workspace_members_user_idx", .on = .{.userId} },
    },
});
