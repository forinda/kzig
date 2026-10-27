//! task-kickdb-api's schema (`src/db/schema/*.ts`), table for table, and its
//! relations (`relations.ts`) for `client.query(…).findMany(.{ .with })`.
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
}, .{ .relations = .{
    .users = .{
        .ownedWorkspaces = .{ .many = .workspaces },
        .workspaceMemberships = .{ .many = .workspace_members },
        .reportedTasks = .{ .many = .tasks },
        .taskAssignees = .{ .many = .task_assignees },
        .comments = .{ .many = .comments },
        .attachments = .{ .many = .attachments },
        .sentMessages = .{ .many = .messages },
        .notifications = .{ .many = .notifications },
        .activities = .{ .many = .activities },
        .channelMemberships = .{ .many = .channel_members },
        .refreshTokens = .{ .many = .refresh_tokens },
        .createdChannels = .{ .many = .channels },
    },
    .refresh_tokens = .{
        .user = .{ .one = .users, .fields = .{.userId}, .references = .{.id} },
    },
    .workspaces = .{
        .owner = .{ .one = .users, .fields = .{.ownerId}, .references = .{.id} },
        .members = .{ .many = .workspace_members },
        .projects = .{ .many = .projects },
        .labels = .{ .many = .labels },
        .channels = .{ .many = .channels },
        .tasks = .{ .many = .tasks },
        .activities = .{ .many = .activities },
    },
    .workspace_members = .{
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .user = .{ .one = .users, .fields = .{.userId}, .references = .{.id} },
    },
    .projects = .{
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .lead = .{ .one = .users, .fields = .{.leadId}, .references = .{.id} },
        .tasks = .{ .many = .tasks },
        .channels = .{ .many = .channels },
        .activities = .{ .many = .activities },
    },
    .tasks = .{
        .project = .{ .one = .projects, .fields = .{.projectId}, .references = .{.id} },
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .reporter = .{ .one = .users, .fields = .{.reporterId}, .references = .{.id} },
        .parentTask = .{ .one = .tasks, .fields = .{.parentTaskId}, .references = .{.id} },
        .subtasks = .{ .many = .tasks },
        .assignees = .{ .many = .task_assignees },
        .labels = .{ .many = .task_labels },
        .comments = .{ .many = .comments },
        .attachments = .{ .many = .attachments },
        .activities = .{ .many = .activities },
    },
    .task_assignees = .{
        .task = .{ .one = .tasks, .fields = .{.taskId}, .references = .{.id} },
        .user = .{ .one = .users, .fields = .{.userId}, .references = .{.id} },
    },
    .labels = .{
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .taskLabels = .{ .many = .task_labels },
    },
    .task_labels = .{
        .task = .{ .one = .tasks, .fields = .{.taskId}, .references = .{.id} },
        .label = .{ .one = .labels, .fields = .{.labelId}, .references = .{.id} },
    },
    .comments = .{
        .task = .{ .one = .tasks, .fields = .{.taskId}, .references = .{.id} },
        .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id} },
    },
    .attachments = .{
        .task = .{ .one = .tasks, .fields = .{.taskId}, .references = .{.id} },
        .uploader = .{ .one = .users, .fields = .{.uploaderId}, .references = .{.id} },
    },
    .channels = .{
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .project = .{ .one = .projects, .fields = .{.projectId}, .references = .{.id} },
        .createdBy = .{ .one = .users, .fields = .{.createdById}, .references = .{.id} },
        .members = .{ .many = .channel_members },
        .messages = .{ .many = .messages },
    },
    .channel_members = .{
        .channel = .{ .one = .channels, .fields = .{.channelId}, .references = .{.id} },
        .user = .{ .one = .users, .fields = .{.userId}, .references = .{.id} },
    },
    .messages = .{
        .channel = .{ .one = .channels, .fields = .{.channelId}, .references = .{.id} },
        .sender = .{ .one = .users, .fields = .{.senderId}, .references = .{.id} },
    },
    .notifications = .{
        .recipient = .{ .one = .users, .fields = .{.recipientId}, .references = .{.id} },
    },
    .activities = .{
        .workspace = .{ .one = .workspaces, .fields = .{.workspaceId}, .references = .{.id} },
        .project = .{ .one = .projects, .fields = .{.projectId}, .references = .{.id} },
        .task = .{ .one = .tasks, .fields = .{.taskId}, .references = .{.id} },
        .actor = .{ .one = .users, .fields = .{.actorId}, .references = .{.id} },
    },
} });
