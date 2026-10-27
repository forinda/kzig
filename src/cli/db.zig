//! `kzig db new|migrate|rollback|status` (KickJS's `kick db …`): migration
//! folders in kick/db's layout, run against `DATABASE_URL`.
const std = @import("std");
const kzig = @import("kzig");
const Names = @import("names.zig").Names;
const dev = @import("dev.zig");

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

/// `kzig db generate` / `check` options.
pub const Opts = struct {
    dir: []const u8 = "db/migrations",
    /// The built app to read the schema from; `zig build` and build.zig's
    /// executable when null.
    exe: ?[]const u8 = null,
    /// Which database adapter's schema (`db_name`); needed when there are several.
    db: ?[]const u8 = null,
    empty: bool = false,
    rename_tables: []const []const u8 = &.{},
    rename_columns: []const []const u8 = &.{},
    /// Ask about drops that could be renames (a terminal on stdin).
    stdin: ?*Io.Reader = null,
    version: []const u8 = "dev",
    /// How long the app may take to print its schema.
    answer_s: i64 = 60,
};

pub fn run(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, o: Out, args: []const []const u8, opts: Opts) !void {
    if (args.len == 0) return error.Usage;
    const cmd = args[0];
    const dir = opts.dir;
    if (std.mem.eql(u8, cmd, "generate")) {
        if (args.len > 2) return error.Usage;
        return generate(io, gpa, a, environ, o, if (args.len == 2) args[1] else "migration", opts);
    }
    if (std.mem.eql(u8, cmd, "check")) {
        if (args.len != 1) return error.Usage;
        return check(io, gpa, a, environ, o, opts);
    }
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

/// The app's schema snapshot: its `App.init` prints it when
/// `KZIG_DB_SNAPSHOT` is set.
fn appSnapshot(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, o: Out, opts: Opts) !kzig.db.snapshot.Snapshot {
    const exe = opts.exe orelse blk: {
        o.say("  zig build\n", .{});
        const built = try std.process.run(gpa, io, .{ .argv = &.{ "zig", "build" } });
        defer gpa.free(built.stdout);
        defer gpa.free(built.stderr);
        if (!built.term.success()) return o.fail("zig build failed:\n{s}", .{built.stderr});
        const bin = try dev.binName(io, a, Io.Dir.cwd()) orelse return o.fail("no addExecutable in build.zig; pass --exe zig-out/bin/<app>\n", .{});
        break :blk try a.print("zig-out/bin/{s}", .{bin});
    };
    var env = try environ.clone(a);
    try env.put("KZIG_DB_SNAPSHOT", opts.db orelse "1");
    // An app built against a kzig that doesn't know the variable would start
    // serving instead of answering.
    const result = std.process.run(gpa, io, .{
        .argv = &.{exe},
        .environ_map = &env,
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(opts.answer_s), .clock = .awake }) },
    }) catch |err| switch (err) {
        error.Timeout => return o.fail("{s} didn't print its schema within {d} s (built against an older kzig?)\n", .{ exe, opts.answer_s }),
        else => return o.fail("{s}: {t}\n", .{ exe, err }),
    };
    defer gpa.free(result.stderr);
    if (!result.term.success() or !std.mem.startsWith(u8, result.stdout, "{")) {
        gpa.free(result.stdout);
        return o.fail("{s} printed no schema: {s}A database adapter brings one with `pub const db_name` and `pub const db_schema`; pick it with --db <name>.\n", .{ exe, result.stderr });
    }
    const text = try a.dupe(u8, result.stdout);
    gpa.free(result.stdout);
    return kzig.db.snapshot.parse(a, text) catch |err| o.fail("the app's snapshot: {t}\n", .{err});
}

/// `old=new`; a column's old side is `table.column`.
pub fn parseRename(raw: []const u8, column: bool) ![2][]const u8 {
    const eq = std.mem.findScalar(u8, raw, '=') orelse return error.BadRename;
    if (eq == 0 or eq == raw.len - 1) return error.BadRename;
    if (column and std.mem.findScalar(u8, raw[0..eq], '.') == null) return error.BadRename;
    return .{ raw[0..eq], raw[eq + 1 ..] };
}

/// kick/db's rename prompt: each drop that could be a rename lists what it
/// could have become; Enter (or end of input) keeps it a drop.
pub fn askRenames(a: Allocator, in: *Io.Reader, o: Out, prev: kzig.db.snapshot.Snapshot, next: kzig.db.snapshot.Snapshot) !kzig.db.diff.Hints {
    const d = kzig.db.diff;
    var tables: std.ArrayList([2][]const u8) = .empty;
    const c = try d.findRenameCandidates(a, prev, next);
    for (c.tables) |t| if (try pick(in, o, try a.print("table {s}", .{t.from}), t.to)) |to| try tables.append(a, .{ t.from, to });
    // Columns of renamed tables too: compare them under their new names.
    const renamed = try a.dupe(kzig.db.snapshot.Table, prev.tables);
    for (renamed) |*t| for (tables.items) |r| if (std.mem.eql(u8, t.name, r[0])) {
        t.name = r[1];
    };
    var shifted = prev;
    shifted.tables = renamed;
    var columns: std.ArrayList([2][]const u8) = .empty;
    const cc = try d.findRenameCandidates(a, shifted, next);
    for (cc.columns) |col| {
        const taken = for (columns.items) |x| {
            if (std.mem.startsWith(u8, x[0], col.table) and x[0].len > col.table.len and x[0][col.table.len] == '.') {
                if (std.mem.eql(u8, x[0][col.table.len + 1 ..], col.from)) break true;
            }
        } else false;
        if (taken) continue;
        var left: std.ArrayList([]const u8) = .empty;
        for (col.to) |to| {
            const used = for (columns.items) |x| {
                if (std.mem.eql(u8, x[1], to) and std.mem.startsWith(u8, x[0], col.table)) break true;
            } else false;
            if (!used) try left.append(a, to);
        }
        if (left.items.len == 0) continue;
        if (try pick(in, o, try a.print("column {s}.{s}", .{ col.table, col.from }), left.items)) |to|
            try columns.append(a, .{ try a.print("{s}.{s}", .{ col.table, col.from }), to });
    }
    return .{ .tables = tables.items, .columns = columns.items, .explicit = true };
}

fn pick(in: *Io.Reader, o: Out, what: []const u8, options: []const []const u8) !?[]const u8 {
    o.out.print("{s} is gone. Renamed to:\n", .{what}) catch {};
    for (options, 1..) |x, i| o.out.print("  [{d}] {s}\n", .{ i, x }) catch {};
    o.say("  (Enter: dropped) > ", .{});
    const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    const answer = std.mem.trim(u8, line, " \t\r\n");
    const n = std.fmt.parseInt(usize, answer, 10) catch return null;
    if (n == 0 or n > options.len) return null;
    return options[n - 1];
}

fn hintsOf(a: Allocator, o: Out, opts: Opts) !kzig.db.diff.Hints {
    var tables: std.ArrayList([2][]const u8) = .empty;
    for (opts.rename_tables) |r| try tables.append(a, parseRename(r, false) catch return o.fail("--rename-table expects old=new, got '{s}'\n", .{r}));
    var columns: std.ArrayList([2][]const u8) = .empty;
    for (opts.rename_columns) |r| try columns.append(a, parseRename(r, true) catch return o.fail("--rename-column expects table.old=new, got '{s}'\n", .{r}));
    return .{ .tables = tables.items, .columns = columns.items };
}

fn generate(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, o: Out, raw: []const u8, opts: Opts) !void {
    const n = Names.init(a, raw) catch return o.fail("a migration name starts with a letter and has letters, digits, '-' or '_'\n", .{});
    const g = kzig.db.generate;
    const target = if (opts.empty) kzig.db.snapshot.Snapshot{} else try appSnapshot(io, gpa, a, environ, o, opts);
    var hints = try hintsOf(a, o, opts);
    const prev = try g.latest(io, a, opts.dir);
    const told = hints.tables.len > 0 or hints.columns.len > 0;
    if (!told and !opts.empty) if (opts.stdin) |in| {
        hints = try askRenames(a, in, o, prev.snapshot, target);
    };
    const r = g.run(io, a, opts.dir, target, .{ .name = n.snake, .now = kzig.db.Timestamp.now(io), .hints = hints, .empty = opts.empty, .version = opts.version }) catch |err| switch (err) {
        error.BadRename => return o.fail("a rename needs the schema to have lost the old name and gained the new one\n", .{}),
        else => return o.fail("generate: {t}\n", .{err}),
    };
    const id = r.id orelse {
        o.say("No schema changes.\n", .{});
        return;
    };
    // Unasked drops that could have been renames: say how to keep them.
    if (!told and opts.stdin == null) {
        const c = try kzig.db.diff.findRenameCandidates(a, prev.snapshot, target);
        for (r.changes) |ch| switch (ch) {
            .drop_table => |t| for (c.tables) |x| if (std.mem.eql(u8, x.from, t.name)) {
                o.err.print("note: {s} is dropped; if it was renamed: --rename-table {s}=<new>\n", .{ t.name, t.name }) catch {};
            },
            .drop_column => |dc| for (c.columns) |x| if (std.mem.eql(u8, x.table, dc.table) and std.mem.eql(u8, x.from, dc.column.name)) {
                o.err.print("note: {s}.{s} is dropped; if it was renamed: --rename-column {s}.{s}=<new>\n", .{ dc.table, dc.column.name, dc.table, dc.column.name }) catch {};
            },
            else => {},
        };
        o.err.flush() catch {};
    }
    const path = try std.fs.path.join(a, &.{ opts.dir, id });
    o.say("  create {s}/up.sql\n  create {s}/down.sql\n  create {s}/snapshot.json\n  create {s}/meta.json\n", .{ path, path, path, path });
    o.say("{d} change(s). Review it, then: kzig db migrate\n", .{r.changes.len});
}

/// For CI: fails when the schema has changes no migration holds.
fn check(io: Io, gpa: Allocator, a: Allocator, environ: *const std.process.Environ.Map, o: Out, opts: Opts) !void {
    const target = try appSnapshot(io, gpa, a, environ, o, opts);
    const prev = try kzig.db.generate.latest(io, a, opts.dir);
    const changes = try kzig.db.diff.diff(a, prev.snapshot, target, .{});
    if (changes.len == 0) {
        o.say("The schema matches {s}.\n", .{prev.id orelse "(no migrations)"});
        return;
    }
    for (changes) |c| o.say("  {t}\n", .{c});
    return o.fail("{d} schema change(s) without a migration: kzig db generate <name>\n", .{changes.len});
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

const testing = std.testing;

test "rename flags: old=new; a column names its table" {
    try testing.expectEqualStrings("users", (try parseRename("users=people", false))[0]);
    try testing.expectEqualStrings("mail", (try parseRename("users.email=mail", true))[1]);
    try testing.expectError(error.BadRename, parseRename("users", false));
    try testing.expectError(error.BadRename, parseRename("=x", false));
    try testing.expectError(error.BadRename, parseRename("email=mail", true));
}

test "rename prompt: a number picks, Enter or end of input drops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const S = kzig.db.snapshot;
    const col = struct {
        fn c(name: []const u8) S.Column {
            return .{ .key = name, .name = name, .sql_type = "text", .nullable = true, .default = null, .default_sql = false, .primary_key = false };
        }
    }.c;
    const t = struct {
        fn t(name: []const u8, cols: []const S.Column) S.Table {
            return .{ .name = name, .columns = cols, .indexes = &.{}, .foreign_keys = &.{}, .checks = &.{}, .primary_key = null };
        }
    }.t;
    const prev: S.Snapshot = .{ .tables = &.{ t("users", &.{ col("id"), col("email") }), t("tags", &.{col("id")}) } };
    const next: S.Snapshot = .{ .tables = &.{ t("people", &.{ col("id"), col("mail"), col("nick") }), t("tags", &.{ col("id"), col("x") }) } };
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: Io.Writer = .fixed(&err_buf);
    // users → people; then people.email → [1] mail; nothing more to ask.
    var in: Io.Reader = .fixed("1\n1\n");
    const h = try askRenames(a, &in, .{ .out = &out, .err = &err }, prev, next);
    try testing.expectEqualStrings("people", h.tables[0][1]);
    try testing.expectEqualStrings("people.email", h.columns[0][0]);
    try testing.expectEqualStrings("mail", h.columns[0][1]);
    try testing.expect(h.explicit);
    try testing.expect(std.mem.find(u8, out.buffered(), "table users is gone") != null);
    var none: Io.Reader = .fixed("");
    const dropped = try askRenames(a, &none, .{ .out = &out, .err = &err }, prev, next);
    try testing.expectEqual(0, dropped.tables.len);
}

test "an app that never answers doesn't hang kzig db check" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "serve.sh", .data = "#!/bin/sh\nexec sleep 30\n", .flags = .{ .permissions = .executable_file } });
    const exe = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/serve.sh", .{tmp.sub_path});
    var out_buf: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: Io.Writer = .fixed(&err_buf);
    var env = try testing.environ.createMap(a);
    _ = &env;
    try testing.expectError(error.Reported, run(testing.io, testing.allocator, a, &env, .{ .out = &out, .err = &err }, &.{"check"}, .{ .exe = exe, .answer_s = 1 }));
    try testing.expect(std.mem.find(u8, err.buffered(), "didn't print its schema within 1 s") != null);
}
