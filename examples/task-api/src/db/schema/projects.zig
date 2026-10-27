const db = @import("kzig").db;

/// A new project's board columns.
const default_status_columns =
    \\'[{"name":"todo","order":0,"color":"#94a3b8"},{"name":"in_progress","order":1,"color":"#3b82f6"},{"name":"in_review","order":2,"color":"#f59e0b"},{"name":"done","order":3,"color":"#22c55e"}]'::jsonb
;

pub const projects = db.table("projects", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .uuid, .not_null = true, .references = .{ .to = "workspaces.id", .on_delete = .cascade } },
    .name = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .key = .{ .type = .{ .varchar = 10 }, .not_null = true },
    .description = .{ .type = .text },
    .leadId = .{ .type = .uuid, .references = .{ .to = "users.id", .on_delete = .set_null } },
    .taskCounter = .{ .type = .integer, .not_null = true, .default = .{ .value = "0" } },
    .isArchived = .{ .type = .boolean, .not_null = true, .default = .{ .value = "false" } },
    .statusColumns = .{ .type = .jsonb, .not_null = true, .default = .{ .value = default_status_columns } },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .keyUnique = .{ .name = "projects_workspace_key_unique", .on = .{ .workspaceId, .key }, .unique = true },
        .workspaceIdx = .{ .name = "projects_workspace_idx", .on = .{.workspaceId} },
    },
});
