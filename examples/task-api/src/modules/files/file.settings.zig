const kzig = @import("kzig");

/// file-storage-api's env: `UPLOAD_DIR`, `MAX_UPLOAD_BYTES`, `API_KEY`,
/// `SIGNING_SECRET`, `PUBLIC_URL`. The two secrets have defaults only in
/// development and test, so production refuses to boot without them.
pub const FileSettings = struct {
    pub const dev_defaults = .{
        .api_key = "dev-api-key-0123456789abcdef0123",
        .signing_secret = "dev-signing-secret-0123456789abcdef",
    };

    /// Relative to the working directory.
    upload_dir: []const u8 = "uploads",
    max_upload_bytes: usize = 5 * 1024 * 1024,
    api_key: []const u8,
    signing_secret: []const u8,
    /// Base of signed URLs; the request's Host when unset.
    public_url: ?[]const u8 = null,

    pub fn validate(self: *const FileSettings, issues: *kzig.Issues) !void {
        if (self.api_key.len < 32) try issues.add("api_key", "must be at least 32 characters");
        if (self.signing_secret.len < 32) try issues.add("signing_secret", "must be at least 32 characters");
    }
};
