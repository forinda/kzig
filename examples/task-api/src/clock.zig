const std = @import("std");
const kzig = @import("kzig");

/// Wall-clock seconds; tests move it forward with `offset_s`.
pub const Clock = struct {
    process: *const kzig.Process,
    offset_s: i64 = 0,

    pub fn now(self: *const Clock) i64 {
        const ns = std.Io.Clock.real.now(self.process.io).toNanoseconds();
        return @as(i64, @intCast(@divTrunc(ns, std.time.ns_per_s))) + self.offset_s;
    }
};

/// `2026-10-27T09:28:37.000Z`, as `Date.toISOString()`.
pub fn iso(arena: std.mem.Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return arena.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

test "iso" {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    try std.testing.expectEqualStrings("2026-10-27T09:28:37.000Z", try iso(fba.allocator(), 1793093317));
}
