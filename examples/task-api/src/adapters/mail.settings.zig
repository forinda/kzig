const kzig = @import("kzig");

/// An SMTP account. `MailSettings("TRANSACTIONAL_MAIL")` reads
/// `TRANSACTIONAL_MAIL_HOST`, `…_PASSWORD` (or `…_PASSWORD_FILE`), …; the
/// password and sender have defaults only under development and test.
pub fn MailSettings(comptime section: []const u8) type {
    return struct {
        pub const prefix = section;
        pub const dev_defaults = .{ .password = "dev-mail-password", .from = "dev@example.com" };

        /// SMTP host.
        host: []const u8 = "localhost",
        port: u16 = 1025,
        /// SMTP user.
        user: []const u8 = "",
        /// SMTP password — or <PREFIX>_PASSWORD_FILE pointing at a mounted secret.
        password: []const u8,
        /// Sender address.
        from: []const u8,

        pub fn validate(self: *const @This(), issues: *kzig.Issues) !void {
            if (self.password.len < 8) try issues.add("password", "must be at least 8 characters");
            if (std.mem.indexOfScalar(u8, self.from, '@') == null) try issues.add("from", "must be an email address");
        }
    };
}

const std = @import("std");

pub const TransactionalMail = MailSettings("TRANSACTIONAL_MAIL");
pub const MarketingMail = MailSettings("MARKETING_MAIL");
