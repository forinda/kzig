//! `kzig db new|migrate|rollback|status` (KickJS's `kick db …`): migration
//! folders in kick/db's layout, run against `DATABASE_URL`.
const std = @import("std");
const kzig = @import("kzig");
const Names = @import("names.zig").Names;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Out = struct {
    out: *Io.Writer,
    err: *Io.Writer,

    fn say(o: Out, comptime fmt: []const u8, args: anytype) void {
        o.out.print(fmt, args) catch {};
        o.out.flush() catch {};
    }

    fn fail(o: Out, comptime fmt: []const u8, args: anytype) error{Reported} {
        o.err.print("error: " ++ fmt, args) catch {};
        o.err.flush() catch {};
        return error.Reported;
    }
};

pub fn run(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, o: Out, args: []const []const u8, dir: []const u8) !void {
    if (args.len == 0) return error.Usage;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "new")) {
        if (args.len != 2) return error.Usage;
        return new(io, a, o, dir, args[1]);
    }
    if (args.len != 1) return error.Usage;
    if (!std.mem.eql(u8, cmd, "migrate") and !std.mem.eql(u8, cmd, "rollback") and !std.mem.eql(u8, cmd, "status")) return error.Usage;
    const url = environ.get("DATABASE_URL") orelse return o.fail("DATABASE_URL is not set (postgres://user:password@host:5432/database)\n", .{});
    var pool = kzig.db.Pool.init(io, gpa, .{ .url = url, .max_connections = 1 }) catch |err|
        return o.fail("DATABASE_URL: {t}\n", .{err});
    defer pool.deinit();
    const list = try kzig.db.migrate.load(io, a, dir);
    const m = kzig.db.migrate;
    if (std.mem.eql(u8, cmd, "migrate")) {
        const r = m.latest(&pool, a, list, .{}) catch |err| return o.fail("migrate: {t}\n", .{err});
        if (r.applied == 0) o.say("Nothing to apply.\n", .{}) else o.say("applied {d} migration(s) as batch {d}\n", .{ r.applied, r.batch });
    } else if (std.mem.eql(u8, cmd, "rollback")) {
        const n = m.rollback(&pool, a, list, .{}) catch |err| return o.fail("rollback: {t}\n", .{err});
        o.say("rolled back {d} migration(s)\n", .{n});
    } else {
        const states = m.status(&pool, a, list, .{}) catch |err| return o.fail("status: {t}\n", .{err});
        if (states.len == 0) o.say("No migrations in {s}\n", .{dir});
        for (states) |s| o.say("{s:<8} {s}\n", .{ @tagName(s.state), s.id });
    }
}

/// `<dir>/<YYYYMMDD_HHMMSS>_<name>/up.sql` and `down.sql`.
fn new(io: Io, a: Allocator, o: Out, dir: []const u8, raw: []const u8) !void {
    const n = Names.init(a, raw) catch return o.fail("a migration name starts with a letter and has letters, digits, '-' or '_'\n", .{});
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
    const days = @divFloor(now, 86400);
    const d = kzig.cron.fromCivil(days);
    const s: u64 = @intCast(now - days * 86400);
    const id = try a.print("{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{s}", .{ @as(u32, @intCast(d.year)), d.month, d.day, s / 3600, s % 3600 / 60, s % 60, n.snake });
    const path = try std.fs.path.join(a, &.{ dir, id });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, path);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "up.sql" }), .data = try a.print("-- {s}: the change. Runs in a transaction with its record.\n", .{n.snake}) });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ path, "down.sql" }), .data = try a.print("-- Undoes {s} (kzig db rollback).\n", .{n.snake}) });
    o.say("  create {s}/up.sql\n  create {s}/down.sql\n", .{ path, path });
}
