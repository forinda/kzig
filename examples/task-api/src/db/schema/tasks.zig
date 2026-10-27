const db = @import("kzig").db;
const enums = @import("enums.zig");

pub const tasks = db.table("tasks", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .projectId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "projects.id", .on_delete = .cascade } },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .key = .{ .type = .{ .varchar = 20 }, .not_null = true, .unique = true },
    .title = .{ .type = .{ .varchar = 500 }, .not_null = true },
    .description = .{ .type = .text },
    .status = .{ .type = .{ .varchar = 50 }, .not_null = true, .default = .{ .value = "todo" } },
    .priority = .{ .type = .{ .@"enum" = enums.TaskPriority }, .not_null = true, .default = .{ .value = "none" } },
    .reporterId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "users.id" } },
    // A self-reference: the string names the table, so no cycle.
    .parentTaskId = .{ .type = .uuid, .references = .{ .to = "tasks.id", .on_delete = .set_null } },
    .dueDate = .{ .type = .timestamp },
    .estimatePoints = .{ .type = .integer },
    .orderIndex = .{ .type = .integer, .not_null = true, .default = .{ .value = "0" } },
    .attachmentCount = .{ .type = .integer, .not_null = true, .default = .{ .value = "0" } },
    .commentCount = .{ .type = .integer, .not_null = true, .default = .{ .value = "0" } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .projectIdx = .{ .name = "tasks_project_idx", .on = .{.projectId} },
        .workspaceIdx = .{ .name = "tasks_workspace_idx", .on = .{.workspaceId} },
        .statusIdx = .{ .name = "tasks_status_idx", .on = .{.status} },
        .parentIdx = .{ .name = "tasks_parent_idx", .on = .{.parentTaskId} },
        .reporterIdx = .{ .name = "tasks_reporter_idx", .on = .{.reporterId} },
    },
});
