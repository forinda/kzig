//! Postgres enum types, declared once and used by the columns.

pub const GlobalRole = enum {
    superadmin,
    user,
    pub const pg_name = "global_role";
};

pub const WorkspaceRole = enum {
    admin,
    member,
    pub const pg_name = "workspace_role";
};

pub const TaskPriority = enum {
    critical,
    high,
    medium,
    low,
    none,
    pub const pg_name = "task_priority";
};

pub const ChannelType = enum {
    public,
    private,
    direct,
    pub const pg_name = "channel_type";
};

pub const NotificationType = enum {
    task_assigned,
    mentioned,
    workspace_invite,
    task_overdue,
    comment_added,
    pub const pg_name = "notification_type";
};
