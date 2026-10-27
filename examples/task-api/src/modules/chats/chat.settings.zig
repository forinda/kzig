const kzig = @import("kzig");

/// ws-chat's `CHAT_SECRET`: signs chat tokens. A default only in
/// development and test.
pub const ChatSettings = struct {
    pub const dev_defaults = .{ .chat_secret = "dev-only-chat-secret-change-me-in-production" };

    chat_secret: []const u8,

    pub fn validate(self: *const ChatSettings, issues: *kzig.Issues) !void {
        if (self.chat_secret.len < 32) try issues.add("chat_secret", "must be at least 32 characters");
    }
};
