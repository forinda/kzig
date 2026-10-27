//! multi-tenant-kickdb-api's `db/schema.ts`, on SQLite: a tenant registry
//! and each tenant's projects (`workspaceId` is the tenant).
const db = @import("kzig").db;

pub const projects = db.table("projects", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .workspaceId = .{ .type = .{ .varchar = 64 }, .not_null = true },
    .title = .{ .type = .{ .varchar = 200 }, .not_null = true },
    .description = .{ .type = .text },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{
        .workspaceIdx = .{ .name = "projects_workspace_idx", .on = .{.workspaceId} },
        // A title is unique within a workspace: the key `import` skips duplicates by.
        .workspaceTitle = .{ .name = "projects_workspace_title_unique", .on = .{ .workspaceId, .title }, .unique = true },
    },
});

/// Not tenanted itself; seeded by the `seed_tenants` migration.
pub const tenants = db.table("tenants", .{
    .id = .{ .type = .{ .varchar = 64 }, .primary_key = true },
    .name = .{ .type = .{ .varchar = 120 }, .not_null = true },
    .subdomain = .{ .type = .{ .varchar = 63 }, .not_null = true, .unique = true },
}, .{});

pub const TenantSchema = db.Schema(.{ .projects = projects, .tenants = tenants }, .{ .dialect = .sqlite });
