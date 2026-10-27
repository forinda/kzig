const db = @import("kzig").db;
const enums = @import("enums.zig");

pub const users = db.table("users", .{
    .id = .{ .type = .uuid, .primary_key = true, .default = .random },
    .email = .{ .type = .{ .varchar = 255 }, .not_null = true, .unique = true },
    .passwordHash = .{ .type = .{ .varchar = 255 }, .not_null = true },
    .firstName = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .lastName = .{ .type = .{ .varchar = 100 }, .not_null = true },
    .avatarUrl = .{ .type = .text },
    .globalRole = .{ .type = .{ .@"enum" = enums.GlobalRole }, .not_null = true, .default = .{ .value = "user" } },
    .isActive = .{ .type = .boolean, .not_null = true, .default = .{ .value = "true" } },
    .lastLoginAt = .{ .type = .timestamp },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
    .updatedAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{
    .indexes = .{ .nameIdx = .{ .name = "users_name_idx", .on = .{ .firstName, .lastName } } },
});
