const db = @import("kzig").db;
const enums = @import("enums.zig");

pub const channels = db.table("channels", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .projectId = .{ .type = .uuid, .references = .{ .to = "projects.id", .on_delete = .set_null } },
    .name = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .description = .{ .type = .text },
    .type = .{ .type = .{ .@"enum" = enums.ChannelType }, .not_null = true, .default = .{ .value = "public" } },
    .createdById = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .nameUnique = .{ .name = "channels_workspace_name_unique", .on = .{ .workspaceId, .name }, .unique = true },
        .workspaceIdx = .{ .name = "channels_workspace_idx", .on = .{.workspaceId} },
        .projectIdx = .{ .name = "channels_project_idx", .on = .{.projectId} },
    },
});
