//! KickJS's `@Cron` (croner underneath): cron expressions, next-run times in
//! a job's timezone, and the scheduler an App runs from `started`.
const std = @import("std");
const builtin = @import("builtin");

/// A parsed expression: one bit per allowed value of each field.
pub const Expr = struct {
    seconds: u64,
    minutes: u64,
    hours: u64,
    days: u64,
    months: u64,
    weekdays: u64,
    /// Both day fields restricted: either may match (croner's legacy mode,
    /// as Vixie cron).
    either_day: bool,
    /// Every hour: such a job also runs in a repeated (fall-back) hour.
    every_hour: bool = false,

    /// 5 fields (`min hour dom mon dow`) or 6 (seconds first).
    pub fn parse(text: []const u8) error{InvalidCron}!Expr {
        var fields: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " \t");
        while (it.next()) |f| {
            if (n == 6) return error.InvalidCron;
            fields[n] = f;
            n += 1;
        }
        if (n != 5 and n != 6) return error.InvalidCron;
        const f = if (n == 6) fields[0..6] else fields[0..5];
        const off: usize = if (n == 6) 1 else 0;
        const dom = f[off + 2];
        const dow = f[off + 4];
        var weekdays = try field(dow, 0, 7, &day_names);
        // 7 is Sunday too.
        if (weekdays & (1 << 7) != 0) weekdays |= 1;
        return .{
            .seconds = if (n == 6) try field(f[0], 0, 59, null) else 1,
            .minutes = try field(f[off], 0, 59, null),
            .hours = try field(f[off + 1], 0, 23, null),
            .every_hour = try field(f[off + 1], 0, 23, null) == (1 << 24) - 1,
            .days = try field(dom, 1, 31, null),
            .months = try field(f[off + 3], 1, 12, &month_names),
            .weekdays = weekdays & 0x7f,
            .either_day = dom[0] != '*' and dom[0] != '?' and dow[0] != '*' and dow[0] != '?',
        };
    }

    fn dayMatches(e: Expr, day: u8, weekday: u8) bool {
        const dom = has(e.days, day);
        const dow = has(e.weekdays, weekday);
        return if (e.either_day) dom or dow else dom and dow;
    }

    /// The first time after `after` (both seconds of wall-clock time, read
    /// as UTC) that the expression matches; null if none within 8 years.
    pub fn next(e: Expr, after: i64) ?i64 {
        var t = after + 1;
        var steps: usize = 0;
        while (steps < 100_000) : (steps += 1) {
            const days = @divFloor(t, 86400);
            const sod = t - days * 86400;
            const date = fromCivil(days);
            const h: u8 = @intCast(@divFloor(sod, 3600));
            const mi: u8 = @intCast(@divFloor(@mod(sod, 3600), 60));
            const s: u8 = @intCast(@mod(sod, 60));
            if (date.year > fromCivil(@divFloor(after, 86400)).year + 8) return null;
            if (!has(e.months, date.month)) {
                t = 86400 * (if (date.month == 12) civil(date.year + 1, 1, 1) else civil(date.year, date.month + 1, 1));
            } else if (!e.dayMatches(date.day, @intCast(@mod(days + 4, 7)))) {
                t = (days + 1) * 86400;
            } else if (!has(e.hours, h)) {
                t = days * 86400 + (@as(i64, h) + 1) * 3600;
            } else if (!has(e.minutes, mi)) {
                t = days * 86400 + @as(i64, h) * 3600 + (@as(i64, mi) + 1) * 60;
            } else if (!has(e.seconds, s)) {
                t += 1;
            } else return t;
        }
        return null;
    }

    /// The first run after `after` (UTC) in `zone`'s wall-clock time,
    /// walked between the zone's offset changes. A local time that doesn't
    /// exist (spring forward) is skipped; in a repeated hour (fall back) a
    /// job whose hour field is `*` keeps running, a fixed time runs once
    /// (Vixie cron's rule).
    pub fn nextIn(e: Expr, zone: *const Zone, after: i64) ?i64 {
        var t = after;
        // Local time already covered before an offset fell back.
        var covered: ?i64 = null;
        for (0..64) |_| {
            const offset = zone.offsetAt(t + 1);
            const end = zone.nextChange(t + 1) orelse std.math.maxInt(i64);
            var from = t + offset;
            if (covered) |c| from = @max(from, c);
            const local = e.next(from) orelse return null;
            const u = local - offset;
            if (u < end) return u;
            if (!e.every_hour) covered = end - 1 + offset;
            t = end - 1;
        }
        return null;
    }
};

fn has(mask: u64, v: u8) bool {
    return mask & (@as(u64, 1) << @intCast(v)) != 0;
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const day_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

/// `*`, `*/n`, `a`, `a-b`, `a-b/n`, `a/n` (a to max), comma lists; names
/// for months (from 1) and weekdays (from 0).
fn field(text: []const u8, min: u8, max: u8, names: ?[]const []const u8) error{InvalidCron}!u64 {
    var mask: u64 = 0;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (item.len == 0) return error.InvalidCron;
        const slash = std.mem.findScalar(u8, item, '/');
        const base = item[0 .. slash orelse item.len];
        const step: u8 = if (slash) |i| std.fmt.parseInt(u8, item[i + 1 ..], 10) catch return error.InvalidCron else 1;
        if (step == 0) return error.InvalidCron;
        var lo: u8 = min;
        var hi: u8 = max;
        if (!std.mem.eql(u8, base, "*") and !std.mem.eql(u8, base, "?")) {
            const dash = std.mem.findScalar(u8, base, '-');
            lo = try value(base[0 .. dash orelse base.len], min, names);
            hi = if (dash) |i| try value(base[i + 1 ..], min, names) else if (slash != null) max else lo;
        }
        if (lo < min or hi > max or lo > hi) return error.InvalidCron;
        var v = lo;
        while (v <= hi) : (v += step) {
            mask |= @as(u64, 1) << @intCast(v);
            if (@as(u16, v) + step > 255) break;
        }
    }
    return mask;
}

fn value(text: []const u8, first: u8, names: ?[]const []const u8) error{InvalidCron}!u8 {
    if (names) |list| for (list, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(text, name)) return @intCast(i + first);
    };
    return std.fmt.parseInt(u8, text, 10) catch error.InvalidCron;
}

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
pub fn civil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Date = struct { year: i32, month: u8, day: u8 };

pub fn fromCivil(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0)), .month = @intCast(m), .day = @intCast(d) };
}

/// A timezone: offsets from a zoneinfo file, then its POSIX rule.
pub const Zone = struct {
    /// UTC offset (seconds east) from each transition on.
    transitions: []const Shift = &.{},
    /// Before the first transition.
    initial: i32 = 0,
    /// After the last transition (the TZif footer).
    rule: ?Rule = null,

    pub const Shift = struct { at: i64, offset: i32 };

    pub const utc: Zone = .{};

    /// `name` (`Africa/Nairobi`) under `dir`, usually `/usr/share/zoneinfo`.
    pub fn load(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8) !Zone {
        if (name.len == 0 or name[0] == '/' or std.mem.find(u8, name, "..") != null) return error.UnknownTimezone;
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '+')) return error.UnknownTimezone;
        const path = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => return error.UnknownTimezone,
            else => return err,
        };
        defer gpa.free(bytes);
        var r: std.Io.Reader = .fixed(bytes);
        var tz = std.tz.Tz.parse(gpa, &r) catch return error.InvalidTimezone;
        defer tz.deinit();
        const shifts = try gpa.alloc(Shift, tz.transitions.len);
        for (tz.transitions, shifts) |t, *s| s.* = .{ .at = t.ts, .offset = t.timetype.offset };
        return .{
            .transitions = shifts,
            .initial = if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0,
            .rule = if (tz.footer) |f| Rule.parse(f) catch null else null,
        };
    }

    pub fn deinit(z: *Zone, gpa: std.mem.Allocator) void {
        gpa.free(z.transitions);
    }

    /// The first offset change after `t`, if any.
    pub fn nextChange(z: *const Zone, t: i64) ?i64 {
        const ts = z.transitions;
        if (ts.len > 0 and t < ts[ts.len - 1].at) {
            // The first transition after `t`.
            var lo: usize = 0;
            var hi: usize = ts.len - 1;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (ts[mid].at > t) hi = mid else lo = mid + 1;
            }
            return ts[lo].at;
        }
        const r = z.rule orelse return null;
        if (r.dst == null) return null;
        const year = fromCivil(@divFloor(t, 86400)).year;
        var best: ?i64 = null;
        for ([_]i32{ year - 1, year, year + 1 }) |y| for (r.changes(y)) |c| {
            if (c > t and (best == null or c < best.?)) best = c;
        };
        return best;
    }

    /// Seconds east of UTC at `t`.
    pub fn offsetAt(z: *const Zone, t: i64) i32 {
        const ts = z.transitions;
        if (ts.len == 0 or t >= ts[ts.len - 1].at) {
            if (z.rule) |r| return r.offsetAt(t);
            return if (ts.len > 0) ts[ts.len - 1].offset else z.initial;
        }
        if (t < ts[0].at) return z.initial;
        // The last transition at or before `t`.
        var lo: usize = 0;
        var hi: usize = ts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (ts[mid].at <= t) lo = mid else hi = mid;
        }
        return ts[lo].offset;
    }
};

/// A POSIX TZ rule (`CET-1CEST,M3.5.0,M10.5.0/3`), as a TZif footer has it.
pub const Rule = struct {
    std_offset: i32,
    dst: ?Dst = null,

    const Dst = struct { offset: i32, start: Change, end: Change };
    /// `Mm.w.d/time`: weekday d of week w (5: the last) of month m.
    const Change = struct { month: u8, week: u8, weekday: u8, time: i32 = 2 * 3600 };

    pub fn parse(text: []const u8) error{InvalidTimezone}!Rule {
        var p: Parser = .{ .s = text };
        try p.name();
        // POSIX offsets are west of UTC: `CET-1` is UTC+1.
        const std_offset = -try p.offset();
        if (p.done()) return .{ .std_offset = std_offset };
        try p.name();
        var dst_offset = std_offset + 3600;
        if (!p.done() and p.peek() != ',') dst_offset = -try p.offset();
        if (!p.eat(',')) return error.InvalidTimezone;
        const start = try p.change();
        if (!p.eat(',')) return error.InvalidTimezone;
        const end = try p.change();
        if (!p.done()) return error.InvalidTimezone;
        return .{ .std_offset = std_offset, .dst = .{ .offset = dst_offset, .start = start, .end = end } };
    }

    /// `year`'s two changes, in UTC: into DST, out of it.
    pub fn changes(r: Rule, year: i32) [2]i64 {
        const d = r.dst.?;
        // In local time: the start in standard time, the end in DST.
        return .{ changeAt(year, d.start) - r.std_offset, changeAt(year, d.end) - d.offset };
    }

    pub fn offsetAt(r: Rule, t: i64) i32 {
        const d = r.dst orelse return r.std_offset;
        const year = fromCivil(@divFloor(t + r.std_offset, 86400)).year;
        const start, const end = r.changes(year);
        const in_dst = if (start < end) t >= start and t < end else !(t >= end and t < start);
        return if (in_dst) d.offset else r.std_offset;
    }

    fn changeAt(year: i32, c: Change) i64 {
        const first = civil(year, c.month, 1);
        const first_weekday: u8 = @intCast(@mod(first + 4, 7));
        var day: i64 = @mod(@as(i64, c.weekday) - first_weekday, 7) + @as(i64, c.week - 1) * 7;
        const next_month = if (c.month == 12) civil(year + 1, 1, 1) else civil(year, c.month + 1, 1);
        while (first + day >= next_month) day -= 7;
        return (first + day) * 86400 + c.time;
    }

    const Parser = struct {
        s: []const u8,
        i: usize = 0,

        fn done(p: *Parser) bool {
            return p.i >= p.s.len;
        }
        fn peek(p: *Parser) u8 {
            return p.s[p.i];
        }
        fn eat(p: *Parser, c: u8) bool {
            if (p.done() or p.s[p.i] != c) return false;
            p.i += 1;
            return true;
        }
        /// `CET` or `<+0530>`.
        fn name(p: *Parser) !void {
            if (p.eat('<')) {
                const end = std.mem.findScalarPos(u8, p.s, p.i, '>') orelse return error.InvalidTimezone;
                p.i = end + 1;
                return;
            }
            const start = p.i;
            while (!p.done() and std.ascii.isAlphabetic(p.peek())) p.i += 1;
            if (p.i - start < 3) return error.InvalidTimezone;
        }
        /// `[+-]hh[:mm[:ss]]` in seconds (hours up to 167, RFC 8536).
        fn offset(p: *Parser) !i32 {
            const sign: i32 = if (p.eat('-')) -1 else if (p.eat('+')) 1 else 1;
            const hours = try p.number();
            if (hours > 167) return error.InvalidTimezone;
            var total: i32 = hours * 3600;
            if (p.eat(':')) total += try p.number() * 60;
            if (p.eat(':')) total += try p.number();
            return sign * total;
        }
        fn number(p: *Parser) !i32 {
            const start = p.i;
            while (!p.done() and std.ascii.isDigit(p.peek()) and p.i - start < 4) p.i += 1;
            return std.fmt.parseInt(i32, p.s[start..p.i], 10) catch error.InvalidTimezone;
        }
        // ponytail: only the `M` form; `Jn` and `n` (Julian days) aren't used
        // by current zoneinfo footers.
        fn change(p: *Parser) !Change {
            if (!p.eat('M')) return error.InvalidTimezone;
            const month = try p.number();
            if (!p.eat('.')) return error.InvalidTimezone;
            const week = try p.number();
            if (!p.eat('.')) return error.InvalidTimezone;
            const weekday = try p.number();
            if (month < 1 or month > 12 or week < 1 or week > 5 or weekday > 6) return error.InvalidTimezone;
            var c: Change = .{ .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) };
            if (p.eat('/')) c.time = try p.offset();
            return c;
        }
    };
};

pub const Trigger = enum { schedule, init, manual };

/// What a job's handler gets (KickJS `CronRun`).
pub const Run = struct {
    name: []const u8,
    expression: []const u8,
    trigger: Trigger,
    /// Unix seconds.
    fired_at: i64,
    /// Freed when the run ends.
    arena: std.mem.Allocator,
};

/// For adapters' `onCronError(err, info)` (KickJS: `onError` with `source: 'cron'`).
pub const ErrorInfo = struct { job: []const u8, expression: []const u8, trigger: Trigger };

pub const Result = struct { ran: usize, failed: usize };

/// `CRON_ENABLED` (false: this process schedules nothing, e.g. on all
/// replicas but one), `CRON_ZONEINFO`.
pub const Settings = struct {
    pub const prefix = "CRON";
    enabled: bool = true,
    zoneinfo: []const u8 = "/usr/share/zoneinfo",
};

pub const Info = struct {
    name: []const u8,
    expression: []const u8,
    description: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    run_on_init: bool = false,
    /// Off (KickJS's default): a run while the last is going is skipped.
    overlap: bool = false,
};

pub const Def = struct { S: type, handler: []const u8, info: Info };

/// Every `pub const crons = .{ .{ .expression, .handler, … } }` of `hosts`.
pub fn defs(comptime hosts: []const type) []const Def {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const Def = &.{};
        for (hosts) |S| {
            if (@typeInfo(S) != .@"struct" or !@hasDecl(S, "crons")) continue;
            for (S.crons) |c| {
                const handler: []const u8 = c.handler;
                const where = @typeName(S) ++ "." ++ handler;
                if (!@hasDecl(S, handler)) @compileError(@typeName(S) ++ ".crons: no handler " ++ handler);
                const expression: []const u8 = c.expression;
                _ = Expr.parse(expression) catch @compileError(where ++ ": invalid cron expression \"" ++ expression ++ "\"");
                const name: []const u8 = if (@hasField(@TypeOf(c), "name")) c.name else shortName(@typeName(S)) ++ "." ++ handler;
                for (out) |d| if (std.mem.eql(u8, d.info.name, name)) @compileError("two cron jobs named " ++ name);
                out = out ++ .{Def{ .S = S, .handler = handler, .info = .{
                    .name = name,
                    .expression = expression,
                    .description = if (@hasField(@TypeOf(c), "description")) c.description else null,
                    .timezone = if (@hasField(@TypeOf(c), "timezone")) c.timezone else null,
                    .run_on_init = if (@hasField(@TypeOf(c), "run_on_init")) c.run_on_init else false,
                    .overlap = if (@hasField(@TypeOf(c), "overlap")) c.overlap else false,
                } }};
            }
        }
        const result = out;
        return result;
    }
}

fn shortName(comptime full: []const u8) []const u8 {
    return full[if (std.mem.findScalarLast(u8, full, '.')) |i| i + 1 else 0..];
}

pub fn infosOf(comptime ds: []const Def) [ds.len]Info {
    var out: [ds.len]Info = undefined;
    for (ds, &out) |d, *o| o.* = d.info;
    return out;
}

pub fn exprsOf(comptime ds: []const Def) [ds.len]Expr {
    @setEvalBranchQuota(1_000_000);
    var out: [ds.len]Expr = undefined;
    for (ds, &out) |d, *o| o.* = Expr.parse(d.info.expression) catch unreachable;
    return out;
}

/// The App's jobs (KickJS `listCronJobs` / `runCronJobs` / the scheduler of
/// `KickCronAdapter`). Inject `*kzig.cron.Jobs` to list or run them.
pub const Jobs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    infos: []const Info,
    exprs: []const Expr,
    zones: []Zone = &.{},
    running: []std.atomic.Value(bool) = &.{},
    scheduling: bool = true,
    /// Set by App (optional, with defaults below, so DI treats them as
    /// plain fields).
    app: ?*anyopaque = null,
    call: *const fn (*anyopaque, usize, Run) anyerror!void = noCall,
    allowed: *const fn (*anyopaque, usize) bool = noAllowed,
    report: *const fn (*anyopaque, anyerror, ErrorInfo) void = noReport,
    scheduler: ?std.Io.Future(std.Io.Cancelable!void) = null,
    /// `start` and `stop` may come from different threads (shutdown from a
    /// signal); once stopped, `start` does nothing.
    lifecycle: std.Io.Mutex = .init,
    stopped: bool = false,
    /// Runs in flight; shutdown waits for them.
    group: std.Io.Group = .init,

    /// Each job's timezone, from `zoneinfo`; an unknown one fails boot.
    pub fn load(j: *Jobs, zoneinfo: []const u8) !void {
        j.running = try j.gpa.alloc(std.atomic.Value(bool), j.infos.len);
        @memset(j.running, .init(false));
        j.zones = try j.gpa.alloc(Zone, j.infos.len);
        @memset(j.zones, Zone.utc);
        errdefer j.deinit();
        for (j.infos, j.zones) |info, *z| if (info.timezone) |tz| {
            z.* = Zone.load(j.io, j.gpa, zoneinfo, tz) catch |err| {
                if (!builtin.is_test) std.log.err("cron job {s}: timezone {s}: {t}", .{ info.name, tz, err });
                return err;
            };
        };
    }

    /// Stops scheduling, waits for runs in flight, frees.
    pub fn deinit(j: *Jobs) void {
        j.stop();
        j.group.await(j.io) catch {};
        for (j.zones) |*z| z.deinit(j.gpa);
        j.gpa.free(j.zones);
        j.gpa.free(j.running);
        j.zones = &.{};
        j.running = &.{};
    }

    pub fn list(j: *const Jobs) []const Info {
        return j.infos;
    }

    pub fn find(j: *const Jobs, name: []const u8) ?usize {
        for (j.infos, 0..) |info, i| if (std.mem.eql(u8, info.name, name)) return i;
        return null;
    }

    /// The service's `cronEnabled(name)`, asked on every tick and run.
    pub fn enabled(j: *const Jobs, i: usize) bool {
        return j.allowed(j.app.?, i);
    }

    /// The first run after `from` (unix seconds) in the job's timezone.
    pub fn next(j: *const Jobs, i: usize, from: i64) ?i64 {
        return j.exprs[i].nextIn(&j.zones[i], from);
    }

    /// Runs the job named `name` now (KickJS `runCronJobs`): skipped when
    /// disabled or still running.
    pub fn run(j: *Jobs, name: []const u8, trigger: Trigger) Result {
        var result: Result = .{ .ran = 0, .failed = 0 };
        for (j.infos, 0..) |info, i| {
            if (!std.mem.eql(u8, info.name, name)) continue;
            switch (j.runOne(i, trigger)) {
                .ran => result.ran += 1,
                .failed => result.failed += 1,
                .skipped => {},
            }
        }
        return result;
    }

    fn runOne(j: *Jobs, i: usize, trigger: Trigger) enum { ran, skipped, failed } {
        const info = j.infos[i];
        if (!j.allowed(j.app.?, i)) return .skipped;
        if (!info.overlap and j.running[i].swap(true, .acq_rel)) {
            if (!builtin.is_test) std.log.warn("{s} is still running — skipped this tick", .{info.name});
            return .skipped;
        }
        defer if (!info.overlap) j.running[i].store(false, .release);
        var arena: std.heap.ArenaAllocator = .init(j.gpa);
        defer arena.deinit();
        const run_info: Run = .{ .name = info.name, .expression = info.expression, .trigger = trigger, .fired_at = @divFloor(nowMs(j.io), 1000), .arena = arena.allocator() };
        j.call(j.app.?, i, run_info) catch |err| {
            if (!builtin.is_test) std.log.err("cron job {s} failed: {t}", .{ info.name, err });
            j.report(j.app.?, err, .{ .job = info.name, .expression = info.expression, .trigger = trigger });
            return .failed;
        };
        return .ran;
    }

    fn spawn(j: *Jobs, i: usize, trigger: Trigger) void {
        // No task to spare: run it here, holding the schedule up meanwhile.
        j.group.concurrent(j.io, runTask, .{ j, i, trigger }) catch {
            _ = j.runOne(i, trigger);
        };
    }

    fn runTask(j: *Jobs, i: usize, trigger: Trigger) void {
        _ = j.runOne(i, trigger);
    }

    /// The server is up: run-on-init jobs, then the schedule.
    pub fn start(j: *Jobs) void {
        j.lifecycle.lockUncancelable(j.io);
        defer j.lifecycle.unlock(j.io);
        if (j.stopped or !j.scheduling or j.infos.len == 0 or j.scheduler != null) return;
        for (j.infos, 0..) |info, i| if (info.run_on_init) j.spawn(i, .init);
        j.scheduler = j.io.concurrent(loop, .{j}) catch |err| blk: {
            if (!builtin.is_test) std.log.err("cron: can't start the scheduler: {t}", .{err});
            break :blk null;
        };
    }

    /// No more ticks; runs in flight carry on (deinit waits for them, as
    /// KickJS does: a job that never returns holds shutdown up).
    pub fn stop(j: *Jobs) void {
        j.lifecycle.lockUncancelable(j.io);
        defer j.lifecycle.unlock(j.io);
        j.stopped = true;
        if (j.scheduler) |*f| f.cancel(j.io) catch {};
        j.scheduler = null;
    }

    /// The job's run is in progress (overlap is off).
    pub fn isRunning(j: *const Jobs, i: usize) bool {
        return j.running[i].load(.acquire);
    }

    fn loop(j: *Jobs) std.Io.Cancelable!void {
        const due = j.gpa.alloc(?i64, j.infos.len) catch return;
        defer j.gpa.free(due);
        const start_s = @divFloor(nowMs(j.io), 1000);
        for (due, 0..) |*d, i| d.* = j.next(i, start_s);
        while (true) {
            const now = nowMs(j.io);
            var earliest: ?i64 = null;
            for (due) |d| if (d) |t| {
                if (earliest == null or t < earliest.?) earliest = t;
            };
            const wait = (earliest orelse return) * 1000 - now;
            if (wait > 0) {
                // Re-checked at least every minute: the wall clock can move.
                try j.io.sleep(.fromMilliseconds(@min(wait, 60_000)), .awake);
                continue;
            }
            const now_s = @divFloor(now, 1000);
            for (due, 0..) |*d, i| if (d.*) |t| if (t <= now_s) {
                j.spawn(i, .schedule);
                d.* = j.next(i, now_s);
            };
        }
    }
};

fn noCall(_: *anyopaque, _: usize, _: Run) anyerror!void {}
fn noAllowed(_: *anyopaque, _: usize) bool {
    return true;
}
fn noReport(_: *anyopaque, _: anyerror, _: ErrorInfo) void {}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_ms));
}

const testing = std.testing;

/// Seconds since the epoch of an ISO-ish UTC time, for tests.
fn at(comptime y: i32, comptime mo: u8, comptime d: u8, comptime h: u8, comptime mi: u8, comptime s: u8) i64 {
    return civil(y, mo, d) * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + s;
}

fn expectNext(expr: []const u8, from: i64, want: i64) !void {
    const e = try Expr.parse(expr);
    try testing.expectEqual(@as(?i64, want), e.next(from));
}

test "next follows each schedule (KickJS's cron.test times)" {
    const from = at(2026, 1, 15, 10, 0, 0);
    try expectNext("*/5 * * * *", from, at(2026, 1, 15, 10, 5, 0));
    try expectNext("*/2 * * * *", from, at(2026, 1, 15, 10, 2, 0));
    try expectNext("0 * * * *", from, at(2026, 1, 15, 11, 0, 0));
    try expectNext("0 2 * * *", from, at(2026, 1, 16, 2, 0, 0));
}

test "names, ranges, steps, lists and seconds" {
    // 2026-01-17 is a Saturday.
    try expectNext("0 9 * * mon-fri", at(2026, 1, 17, 12, 0, 0), at(2026, 1, 19, 9, 0, 0));
    try expectNext("30 8 * jan,mar *", at(2026, 1, 31, 9, 0, 0), at(2026, 3, 1, 8, 30, 0));
    try expectNext("0 0 * * 7", at(2026, 1, 15, 0, 0, 0), at(2026, 1, 18, 0, 0, 0));
    try expectNext("10-20/5 * * * *", at(2026, 1, 15, 10, 16, 0), at(2026, 1, 15, 10, 20, 0));
    try expectNext("*/10 * * * * *", at(2026, 1, 15, 10, 0, 0), at(2026, 1, 15, 10, 0, 10));
}

test "day of month and day of week: either matches" {
    // The 13th, or any Friday: from Wed 2026-01-14, Friday the 16th comes first.
    try expectNext("0 0 13 * fri", at(2026, 1, 14, 0, 0, 0), at(2026, 1, 16, 0, 0, 0));
    try expectNext("0 0 13 * fri", at(2026, 2, 12, 1, 0, 0), at(2026, 2, 13, 0, 0, 0));
}

test "months without the day are skipped" {
    try expectNext("0 0 31 * *", at(2026, 1, 31, 1, 0, 0), at(2026, 3, 31, 0, 0, 0));
    try expectNext("0 0 29 2 *", at(2026, 1, 1, 0, 0, 0), at(2028, 2, 29, 0, 0, 0));
    try testing.expectEqual(@as(?i64, null), (try Expr.parse("0 0 30 2 *")).next(at(2026, 1, 1, 0, 0, 0)));
}

test "bad expressions" {
    for ([_][]const u8{ "61 * * * *", "* * *", "*/0 * * * *", "a b c d e", "5-1 * * * *", "* * * * 8", "* * * * * * *", "1,,2 * * * *" }) |bad|
        try testing.expectError(error.InvalidCron, Expr.parse(bad));
}

fn loadZone(name: []const u8) !Zone {
    return Zone.load(testing.io, testing.allocator, "/usr/share/zoneinfo", name);
}

test "zone offsets from zoneinfo: transitions and the footer's rule" {
    var nairobi = try loadZone("Africa/Nairobi");
    defer nairobi.deinit(testing.allocator);
    try testing.expectEqual(3 * 3600, nairobi.offsetAt(at(2026, 1, 15, 0, 0, 0)));
    var berlin = try loadZone("Europe/Berlin");
    defer berlin.deinit(testing.allocator);
    try testing.expectEqual(3600, berlin.offsetAt(at(2026, 1, 15, 12, 0, 0)));
    try testing.expectEqual(7200, berlin.offsetAt(at(2026, 7, 15, 12, 0, 0)));
    // Past any zone file's table: the POSIX rule decides.
    try testing.expectEqual(7200, berlin.offsetAt(at(2045, 7, 1, 0, 0, 0)));
    try testing.expectEqual(3600, berlin.offsetAt(at(2045, 12, 1, 0, 0, 0)));
    try testing.expectError(error.UnknownTimezone, loadZone("Mars/Olympus"));
    try testing.expectError(error.UnknownTimezone, loadZone("../../etc/passwd"));
}

test "POSIX TZ rules" {
    const cet = try Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3");
    try testing.expectEqual(3600, cet.offsetAt(at(2030, 3, 31, 0, 59, 59)));
    try testing.expectEqual(7200, cet.offsetAt(at(2030, 3, 31, 1, 0, 0)));
    try testing.expectEqual(7200, cet.offsetAt(at(2030, 10, 27, 0, 59, 59)));
    try testing.expectEqual(3600, cet.offsetAt(at(2030, 10, 27, 1, 0, 0)));
    try testing.expectEqual(-5 * 3600, (try Rule.parse("EST5EDT,M3.2.0,M11.1.0")).offsetAt(at(2030, 1, 1, 0, 0, 0)));
    try testing.expectEqual(5 * 3600 + 1800, (try Rule.parse("<+0530>-5:30")).offsetAt(0));
    try testing.expectEqual(3 * 3600, (try Rule.parse("EAT-3")).offsetAt(0));
}

test "next run in a zone (KickJS's cron.test: 02:00 Nairobi is 23:00 UTC)" {
    var nairobi = try loadZone("Africa/Nairobi");
    defer nairobi.deinit(testing.allocator);
    const e = try Expr.parse("0 2 * * *");
    try testing.expectEqual(@as(?i64, at(2026, 1, 15, 23, 0, 0)), e.nextIn(&nairobi, at(2026, 1, 15, 10, 0, 0)));
    try testing.expectEqual(@as(?i64, at(2026, 1, 16, 23, 0, 0)), e.nextIn(&nairobi, at(2026, 1, 15, 23, 30, 0)));
    var berlin = try loadZone("Europe/Berlin");
    defer berlin.deinit(testing.allocator);
    const noon = try Expr.parse("0 12 * * *");
    try testing.expectEqual(@as(?i64, at(2026, 1, 15, 11, 0, 0)), noon.nextIn(&berlin, at(2026, 1, 15, 0, 0, 0)));
    try testing.expectEqual(@as(?i64, at(2026, 7, 15, 10, 0, 0)), noon.nextIn(&berlin, at(2026, 7, 15, 0, 0, 0)));
}

const app_mod = @import("../core/app.zig");

const Ticker = struct {
    ticks: std.atomic.Value(u32) = .init(0),
    boots: std.atomic.Value(u32) = .init(0),

    pub const crons = .{
        .{ .expression = "* * * * * *", .handler = "tick", .name = "tick" },
        .{ .expression = "0 0 1 1 *", .handler = "boot", .name = "boot", .run_on_init = true, .description = "At boot" },
        .{ .expression = "0 2 * * *", .handler = "slow", .name = "slow", .timezone = "Africa/Nairobi" },
        .{ .expression = "0 0 1 1 *", .handler = "broken" },
        .{ .expression = "0 0 1 1 *", .handler = "off", .name = "off" },
    };

    pub fn cronEnabled(_: *Ticker, name: []const u8) bool {
        return !std.mem.eql(u8, name, "off");
    }
    pub fn tick(self: *Ticker, _: Run) void {
        _ = self.ticks.fetchAdd(1, .acq_rel);
    }
    pub fn boot(self: *Ticker, run: Run) void {
        if (run.trigger == .init) _ = self.boots.fetchAdd(1, .acq_rel);
    }
    pub fn slow(_: *Ticker, _: Run) !void {
        try testing.io.sleep(.fromMilliseconds(200), .awake);
    }
    pub fn broken(_: *Ticker, _: Run) !void {
        return error.SupplierDown;
    }
    pub fn off(_: *Ticker, _: Run) void {}
};

const Reports = struct {
    last: ?ErrorInfo = null,
    err: ?anyerror = null,

    pub fn onCronError(self: *Reports, err: anyerror, info: ErrorInfo) void {
        self.err = err;
        self.last = info;
    }
};

const JobsApp = app_mod.App(.{
    .modules = &.{app_mod.Module(.{ .name = "Jobs", .services = &.{Ticker} })},
    .adapters = &.{Reports},
});

fn bootJobs(app: *JobsApp, vars: []const [2][]const u8) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NODE_ENV", "test");
    for (vars) |v| try env.put(v[0], v[1]);
    try app.init(testing.io, testing.allocator, &env);
}

test "jobs: listed with names, schedules and next runs" {
    var app: JobsApp = undefined;
    try bootJobs(&app, &.{});
    defer app.deinit();
    const jobs = app.get(Jobs);
    try testing.expectEqual(5, jobs.list().len);
    const slow = jobs.find("slow").?;
    try testing.expectEqualStrings("Africa/Nairobi", jobs.list()[slow].timezone.?);
    try testing.expectEqual(@as(?i64, at(2026, 1, 15, 23, 0, 0)), jobs.next(slow, at(2026, 1, 15, 10, 0, 0)));
    // No name: the type's and the handler's.
    try testing.expect(jobs.find("Ticker.broken") != null);
    try testing.expectEqualStrings("At boot", jobs.list()[jobs.find("boot").?].description.?);
}

test "jobs: run by hand; disabled skipped; a failure reaches onCronError" {
    var app: JobsApp = undefined;
    try bootJobs(&app, &.{});
    defer app.deinit();
    const jobs = app.get(Jobs);
    try testing.expectEqual(Result{ .ran = 1, .failed = 0 }, jobs.run("tick", .manual));
    try testing.expectEqual(Result{ .ran = 0, .failed = 0 }, jobs.run("off", .manual));
    try testing.expectEqual(Result{ .ran = 0, .failed = 1 }, jobs.run("Ticker.broken", .manual));
    const info = app.get(Reports).last.?;
    try testing.expectEqualStrings("Ticker.broken", info.job);
    try testing.expectEqualStrings("0 0 1 1 *", info.expression);
    try testing.expectEqual(Trigger.manual, info.trigger);
    try testing.expectEqual(error.SupplierDown, app.get(Reports).err.?);
}

test "jobs: a run while the last is still going is skipped" {
    var app: JobsApp = undefined;
    try bootJobs(&app, &.{});
    defer app.deinit();
    const jobs = app.get(Jobs);
    var first = try testing.io.concurrent(Jobs.run, .{ jobs, "slow", Trigger.manual });
    while (!jobs.isRunning(jobs.find("slow").?)) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(Result{ .ran = 0, .failed = 0 }, jobs.run("slow", .manual));
    try testing.expectEqual(Result{ .ran = 1, .failed = 0 }, first.await(testing.io));
}

test "jobs: the scheduler runs on its schedule and at boot" {
    var app: JobsApp = undefined;
    try bootJobs(&app, &.{});
    defer app.deinit();
    app.started(.{ .port = 0 });
    try testing.io.sleep(.fromMilliseconds(2100), .awake);
    app.beginDrain();
    try testing.expect(app.get(Ticker).ticks.load(.acquire) >= 1);
    try testing.expectEqual(1, app.get(Ticker).boots.load(.acquire));
}

test "jobs: CRON_ENABLED=false schedules nothing" {
    var app: JobsApp = undefined;
    try bootJobs(&app, &.{.{ "CRON_ENABLED", "false" }});
    defer app.deinit();
    app.started(.{ .port = 0 });
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    app.beginDrain();
    try testing.expectEqual(0, app.get(Ticker).boots.load(.acquire));
}

test "DST: spring-forward never ends a schedule; a missing local time is skipped" {
    const berlin: Zone = .{ .rule = try Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3") };
    const every = try Expr.parse("* * * * *");
    try testing.expectEqual(@as(?i64, at(2030, 3, 31, 1, 0, 0)), every.nextIn(&berlin, at(2030, 3, 31, 0, 59, 0)));
    // 02:30 doesn't exist that day: the next is the 1st's (CEST, 00:30 UTC).
    const daily = try Expr.parse("30 2 * * *");
    try testing.expectEqual(@as(?i64, at(2030, 4, 1, 0, 30, 0)), daily.nextIn(&berlin, at(2030, 3, 31, 0, 0, 0)));
    const sydney: Zone = .{ .rule = try Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3") };
    // AEDT starts 2030-10-06 02:00 local (16:00 UTC the day before).
    try testing.expectEqual(@as(?i64, at(2030, 10, 5, 16, 0, 0)), every.nextIn(&sydney, at(2030, 10, 5, 15, 59, 0)));
}

test "DST: the repeated hour runs wildcard-hour jobs, fixed times once" {
    const berlin: Zone = .{ .rule = try Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3") };
    // CEST ends 2030-10-27 03:00 local (01:00 UTC); 02:00-03:00 repeats.
    const every = try Expr.parse("* * * * *");
    try testing.expectEqual(@as(?i64, at(2030, 10, 27, 1, 0, 0)), every.nextIn(&berlin, at(2030, 10, 27, 0, 59, 0)));
    const daily = try Expr.parse("30 2 * * *");
    try testing.expectEqual(@as(?i64, at(2030, 10, 27, 0, 30, 0)), daily.nextIn(&berlin, at(2030, 10, 27, 0, 0, 0)));
    try testing.expectEqual(@as(?i64, at(2030, 10, 28, 1, 30, 0)), daily.nextIn(&berlin, at(2030, 10, 27, 0, 30, 0)));
}

test "jobs: an unknown timezone fails boot without leaking" {
    var app: JobsApp = undefined;
    try testing.expectError(error.UnknownTimezone, bootJobs(&app, &.{.{ "CRON_ZONEINFO", "/nonexistent-zoneinfo" }}));
}
