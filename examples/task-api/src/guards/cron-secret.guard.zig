const std = @import("std");
const kzig = @import("kzig");
const CronJobSettings = @import("../modules/crons/cron.settings.zig").CronJobSettings;

const Sha256 = std.crypto.hash.sha2.Sha256;

/// `Authorization: Bearer $CRON_SECRET` or 401, compared in constant time.
pub const CronSecretGuard = struct {
    settings: *const CronJobSettings,

    pub fn handle(self: *CronSecretGuard, ctx: *kzig.Ctx, next: *kzig.Next) !void {
        var expected: [Sha256.digest_length]u8 = undefined;
        var h = Sha256.init(.{});
        h.update("Bearer ");
        h.update(self.settings.secret);
        h.final(&expected);
        var given: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(ctx.header("authorization") orelse "", &given, .{});
        if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, expected, given))
            return ctx.fail(.unauthorized, "Missing or invalid CRON_SECRET bearer token");
        next.run();
    }
};
