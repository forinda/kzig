# Validation, list queries and settings

The schema is the type. `body`, `query` and `params` in a `got` struct are decoded from the
request; every problem is reported with its path, as a 422 problem body:

```zig
pub const CreateProject = struct {
    title: []const u8,
    description: ?[]const u8 = null,

    pub fn validate(self: *const CreateProject, issues: *kzig.Issues) !void {
        if (self.title.len < 1 or self.title.len > 200) try issues.add("title", "must be 1 to 200 characters");
    }
};

// A list endpoint (sketch; tasks arrive in a later milestone):
pub fn list(self: *TaskController, ctx: *kzig.Ctx, got: struct {
    query: kzig.ListQuery(.{ .filterable = &.{"status"}, .sortable = &.{"created"} }),
}) !kzig.Paginated(Task) {
    // ?filter=status:eq:open&sort=-created&page=2&limit=20
    const rows = try self.tasks.find(ctx.arena, got.query);
    return got.query.paginate(ctx, Task, rows.items, rows.total);
}
```

Settings sections are structs with a prefix, read and validated at boot when the module that
declares them is mounted:

```zig
pub const FeatureSettings = struct {
    pub const prefix = "FEATURES";
    signups: bool = true, // FEATURES_SIGNUPS
    beta_testers: []const []const u8 = &.{}, // FEATURES_BETA_TESTERS=a@x.io,b@x.io
};

pub const AppSettings = struct {
    pub const prefix = "APP";
    pub const dev_defaults = .{ .public_url = "http://localhost:3000" }; // only when NODE_ENV is development/test
    public_url: []const u8, // APP_PUBLIC_URL, or APP_PUBLIC_URL_FILE=/run/secrets/…
};
```
