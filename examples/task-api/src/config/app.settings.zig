/// `APP_NAME`, `APP_PUBLIC_URL`. The URL has a default only when `NODE_ENV`
/// is development or test, so production refuses to boot without it.
pub const AppSettings = struct {
    pub const prefix = "APP";
    pub const dev_defaults = .{ .public_url = "http://localhost:3000" };

    /// Display name.
    name: []const u8 = "task-api",
    /// Where clients reach this API (links in emails).
    public_url: []const u8,
};
