//! task-kickdb-api's schema (`src/db/schema/*.ts`), table for table.
const kzig = @import("kzig");

pub const enums = @import("schema/enums.zig");

pub const Schema = kzig.db.Schema(.{
    .users = @import("schema/users.zig").users,
    .refresh_tokens = @import("schema/refresh_tokens.zig").refresh_tokens,
    .workspaces = @import("schema/workspaces.zig").workspaces,
    .workspace_members = @import("schema/workspace_members.zig").workspace_members,
    .projects = @import("schema/projects.zig").projects,
    .tasks = @import("schema/tasks.zig").tasks,
    .task_assignees = @import("schema/task_assignees.zig").task_assignees,
    .labels = @import("schema/labels.zig").labels,
    .task_labels = @import("schema/task_labels.zig").task_labels,
    .comments = @import("schema/comments.zig").comments,
    .attachments = @import("schema/attachments.zig").attachments,
    .channels = @import("schema/channels.zig").channels,
    .channel_members = @import("schema/channel_members.zig").channel_members,
    .messages = @import("schema/messages.zig").messages,
    .notifications = @import("schema/notifications.zig").notifications,
    .activities = @import("schema/activities.zig").activities,
}, .{});
