//! A point in time as Postgres's timestamp, timestamptz and date columns
//! hold it, and as KickJS sends a `Date`: ISO 8601 in JSON.
const std = @import("std");
const Io = std.Io;

/// Microseconds since 1970-01-01T00:00:00Z. A `timestamp` column (no zone)
/// is read as UTC; a `date` is its midnight.
pub const Timestamp = struct {
    us: i64,

    pub const openapi_schema = "{\"type\":\"string\",\"format\":\"date-time\"}";
    pub const json_expected = "date-time";

    pub fn now(io: Io) Timestamp {
        return .{ .us = @intCast(@divFloor(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_us)) };
    }

    /// `YYYY-MM-DD`, then optionally ` ` or `T`, `HH:MM:SS`, up to six
    /// fraction digits, and `Z` or `±HH[:MM]`: what Postgres sends and what
    /// JSON clients send.
    pub fn parse(text: []const u8) error{InvalidTimestamp}!Timestamp {
        var p: Parser = .{ .s = text };
        const year = try p.num(4);
        try p.lit('-');
        const month = try p.num(2);
        try p.lit('-');
        const day = try p.num(2);
        if (month < 1 or month > 12 or day < 1 or day > std.time.epoch.getDaysInMonth(@intCast(year), @fromBackingInt(@intCast(month)))) return error.InvalidTimestamp;
        var secs: i64 = 0;
        var frac: i64 = 0;
        if (p.i < text.len) {
            if (text[p.i] != ' ' and text[p.i] != 'T') return error.InvalidTimestamp;
            p.i += 1;
            const h = try p.num(2);
            try p.lit(':');
            const m = try p.num(2);
            try p.lit(':');
            const sec = try p.num(2);
            if (h > 23 or m > 59 or sec > 59) return error.InvalidTimestamp;
            secs = h * 3600 + m * 60 + sec;
            if (p.i < text.len and text[p.i] == '.') {
                p.i += 1;
                var digits: u32 = 0;
                while (p.i < text.len and std.ascii.isDigit(text[p.i])) : (p.i += 1) {
                    digits += 1;
                    if (digits > 6) return error.InvalidTimestamp;
                    frac = frac * 10 + (text[p.i] - '0');
                }
                if (digits == 0) return error.InvalidTimestamp;
                while (digits < 6) : (digits += 1) frac *= 10;
            }
            if (p.i < text.len) switch (text[p.i]) {
                'Z' => p.i += 1,
                // ±HH, ±HH:MM, ±HH:MM:SS (old zones, LMT), as Postgres prints them.
                '+', '-' => |sign| {
                    p.i += 1;
                    const oh = try p.num(2);
                    var om: i64 = 0;
                    var os: i64 = 0;
                    if (p.i < text.len) {
                        if (text[p.i] == ':') p.i += 1;
                        om = try p.num(2);
                        if (p.i < text.len and text[p.i] == ':') {
                            p.i += 1;
                            os = try p.num(2);
                        }
                    }
                    if (oh > 15 or om > 59 or os > 59) return error.InvalidTimestamp;
                    const off = oh * 3600 + om * 60 + os;
                    secs -= if (sign == '+') off else -off;
                },
                else => return error.InvalidTimestamp,
            };
        }
        if (p.i != text.len) return error.InvalidTimestamp;
        return .{ .us = (daysFromCivil(year, month, day) * 86400 + secs) * std.time.us_per_s + frac };
    }

    pub fn format(self: Timestamp, w: *Io.Writer) Io.Writer.Error!void {
        const secs = @divFloor(self.us, std.time.us_per_s);
        const frac: u64 = @intCast(@mod(self.us, std.time.us_per_s));
        const days = @divFloor(secs, 86400);
        const day_secs: u64 = @intCast(@mod(secs, 86400));
        const c = civilFromDays(days);
        // Years before 1 aren't written (Postgres would want `BC`).
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@max(c.year, 0))), c.month, c.day, day_secs / 3600, day_secs % 3600 / 60, day_secs % 60 });
        if (frac != 0) {
            var buf: [6]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>6}", .{frac}) catch unreachable;
            try w.print(".{s}", .{std.mem.trimEnd(u8, &buf, "0")});
        }
        try w.writeByte('Z');
    }

    /// As KickJS's `Date.toJSON`: always milliseconds (`.000Z`); finer
    /// digits are dropped, as a `Date` drops them.
    pub fn jsonStringify(self: Timestamp, jw: anytype) !void {
        var buf: [40]u8 = undefined;
        const ms: Timestamp = .{ .us = @divFloor(self.us, 1000) * 1000 };
        const iso = std.fmt.bufPrint(&buf, "{f}", .{ms}) catch unreachable;
        // `{f}` trims the fraction; put back three digits.
        const frac = if (std.mem.findScalar(u8, iso, '.')) |dot| iso[dot + 1 .. iso.len - 1] else "";
        var out: [40]u8 = undefined;
        const head = iso[0..19];
        const s = std.fmt.bufPrint(&out, "{s}.{s}{s}Z", .{ head, frac, "000"[frac.len..] }) catch unreachable;
        try jw.write(s);
    }

    pub fn fromPg(text: []const u8) !Timestamp {
        return parse(text) catch error.DbDecode;
    }

    pub fn toPg(self: Timestamp, a: std.mem.Allocator) ![]const u8 {
        return a.print("{f}", .{self});
    }

    /// As kick/db stores a timestamp on SQLite: `YYYY-MM-DD HH:MM:SS.SSS`,
    /// UTC, so stored values sort as text.
    pub fn toSqlite(self: Timestamp, a: std.mem.Allocator) ![]const u8 {
        const iso = try self.toPg(a); // YYYY-MM-DDTHH:MM:SS[.ffffff]Z
        const ms = @divFloor(@mod(self.us, std.time.us_per_s), std.time.us_per_ms);
        return a.print("{s} {s}.{d:0>3}", .{ iso[0..10], iso[11..19], @as(u64, @intCast(ms)) });
    }

    /// A request body's value; null when it isn't a date-time string.
    pub fn fromJsonValue(v: std.json.Value) ?Timestamp {
        return if (v == .string) parse(v.string) catch null else null;
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn num(p: *Parser, comptime n: usize) !i64 {
        if (p.i + n > p.s.len) return error.InvalidTimestamp;
        var v: i64 = 0;
        for (p.s[p.i..][0..n]) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
            v = v * 10 + (c - '0');
        }
        p.i += n;
        return v;
    }

    fn lit(p: *Parser, c: u8) !void {
        if (p.i >= p.s.len or p.s[p.i] != c) return error.InvalidTimestamp;
        p.i += 1;
    }
};

// Howard Hinnant's days_from_civil / civil_from_days (proleptic Gregorian).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { year: i64, month: u8, day: u8 } {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

const testing = std.testing;

test "parse: Postgres text, offsets, fractions, date-only and ISO 8601" {
    try testing.expectEqual(1793102400000000, (try Timestamp.parse("2026-10-27 12:00:00")).us);
    try testing.expectEqual(1793102400000000, (try Timestamp.parse("2026-10-27T12:00:00Z")).us);
    try testing.expectEqual(1793091600500000, (try Timestamp.parse("2026-10-27 12:00:00.5+03")).us);
    try testing.expectEqual(1793082600000000, (try Timestamp.parse("2026-10-27 12:00:00+05:30")).us);
    try testing.expectEqual(-1, (try Timestamp.parse("1969-12-31 23:59:59.999999")).us);
    try testing.expectEqual(1793059200000000, (try Timestamp.parse("2026-10-27")).us);
    for ([_][]const u8{ "", "2026-13-01", "2026-10-27 25:00:00", "yesterday", "2026-10-27 12:00:00+", "2026-10-27 12:00:00.1234567" }) |bad| {
        try testing.expectError(error.InvalidTimestamp, Timestamp.parse(bad));
    }
}

test "parse: offsets with seconds (old zones); offsets out of range are refused" {
    try testing.expectEqual(-2208988800000000, (try Timestamp.parse("1900-01-01 02:27:16+02:27:16")).us);
    try testing.expectError(error.InvalidTimestamp, Timestamp.parse("2026-10-27 12:00:00+99"));
    try testing.expectError(error.InvalidTimestamp, Timestamp.parse("2026-10-27 12:00:00+05:60"));
}

test "JSON: milliseconds always, as KickJS's Date.toJSON writes them" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, .{ .a = Timestamp{ .us = 0 }, .b = Timestamp{ .us = 1793091600512345 } }, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"a\":\"1970-01-01T00:00:00.000Z\",\"b\":\"2026-10-27T09:00:00.512Z\"}", json);
}

test "a request body can carry a Timestamp" {
    const decode = @import("../core/decode.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var issues: decode.Issues = .init(a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"at\":\"2026-10-27T12:00:00Z\"}", .{});
    try testing.expectEqual(1793102400000000, (try decode.json(struct { at: Timestamp }, a, v, &issues)).?.at.us);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"at\":\"soon\"}", .{});
    try testing.expectEqual(null, try decode.json(struct { at: Timestamp }, a, bad, &issues));
    try testing.expectEqualStrings("expected date-time", issues.list.items[0].message);
}

test "format: ISO 8601 in UTC, fraction only when there is one" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2026-10-27T12:00:00Z", try std.fmt.bufPrint(&buf, "{f}", .{Timestamp{ .us = 1793102400000000 }}));
    try testing.expectEqualStrings("2026-10-27T09:00:00.5Z", try std.fmt.bufPrint(&buf, "{f}", .{Timestamp{ .us = 1793091600500000 }}));
    try testing.expectEqualStrings("1969-12-31T23:59:59.999999Z", try std.fmt.bufPrint(&buf, "{f}", .{Timestamp{ .us = -1 }}));
}
