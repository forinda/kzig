const db = @import("kzig").db;

pub const activities = db.table("activities", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .projectId = .{ .type = .uuid, .references = .{ .to = "projects.id", .on_delete = .set_null } },
    .taskId = .{ .type = .uuid, .references = .{ .to = "tasks.id", .on_delete = .set_null } },
    .actorId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    .action = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .changes = .{ .type = .jsonb },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .workspaceIdx = .{ .name = "activities_workspace_idx", .on = .{.workspaceId} },
        .actorIdx = .{ .name = "activities_actor_idx", .on = .{.actorId} },
        .createdIdx = .{ .name = "activities_created_idx", .on = .{.createdAt} },
    },
});
