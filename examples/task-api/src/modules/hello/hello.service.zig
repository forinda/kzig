const std = @import("std");
const kzig = @import("kzig");

pub const HelloService = struct {
    process: *const kzig.Process,

    pub const Greeting = struct { message: []const u8, timestamp: []const u8 };
    pub const Health = struct { status: []const u8, uptime: f64 };

    pub fn greet(self: *HelloService, arena: std.mem.Allocator, name: []const u8) !Greeting {
        return .{
            .message = try arena.print("Hello {s} from kzig!", .{name}),
            .timestamp = try isoNow(arena, self.process.io),
        };
    }

    pub fn healthCheck(self: *HelloService) Health {
        return .{ .status = "ok", .uptime = self.process.uptime() };
    }
};

/// `new Date().toISOString()`: `2026-10-27T04:29:52.123Z`.
fn isoNow(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const ms: u64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_ms));
    const secs: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const t = secs.getDaySeconds();
    return arena.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,            md.month.numeric(),     md.day_index + 1,
        t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute(),
        ms % 1000,
    });
}
