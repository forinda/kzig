const std = @import("std");
const kzig = @import("kzig");

/// One adapter, many instances: each `MailAdapter(name, Settings)` is its own
/// type with its own settings section and health check (KickJS
/// `MailAdapter.scoped('transactional', { settings: TransactionalMail })`).
pub fn MailAdapter(comptime name: []const u8, comptime Settings: type) type {
    return struct {
        const Self = @This();
        pub const settings = &.{Settings};

        mail: *const Settings,
        process: *const kzig.Process,

        /// Up when the SMTP server accepts a TCP connection within 1 s.
        pub fn onHealthCheck(self: *Self) kzig.HealthCheck {
            return .{ .name = "MailAdapter:" ++ name, .status = if (self.reachable()) .up else .down };
        }

        fn reachable(self: *Self) bool {
            // Std's threaded Io has no connect timeout yet; race a sleep.
            const io = self.process.io;
            const Result = union(enum) { connected: bool, timed_out: void };
            var buf: [2]Result = undefined;
            var race: std.Io.Select(Result) = .init(io, &buf);
            defer race.cancelDiscard();
            race.concurrent(.connected, connect, .{ io, self.mail.host, self.mail.port }) catch return false;
            race.concurrent(.timed_out, wait, .{ io, 1000 }) catch return false;
            return switch (race.await() catch return false) {
                .connected => |ok| ok,
                .timed_out => false,
            };
        }

        fn connect(io: std.Io, host: []const u8, port: u16) bool {
            const host_name = std.Io.net.HostName.init(host) catch return false;
            const stream = host_name.connect(io, port, .{ .mode = .stream }) catch return false;
            stream.close(io);
            return true;
        }

        fn wait(io: std.Io, ms: i64) void {
            io.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };
}
