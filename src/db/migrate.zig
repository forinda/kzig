//! kick/db's migrations: folders `<id>/up.sql` (and `down.sql`,
//! `snapshot.json`), recorded in `kick_migrations` with the same columns
//! and hash, so a project can move between KickJS and kzig. Each runs in a
//! transaction with its record; `kick_migrations_lock` keeps two runs apart.
const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Migration = struct {
    /// The folder's name: `20261015_231323_init`.
    id: []const u8,
    /// After the timestamp: `init`.
    name: []const u8,
    up: []const u8,
    down: []const u8,
    hash: []const u8,
};

pub const State = enum { applied, pending, changed };
pub const Status = struct { id: []const u8, name: []const u8, state: State, batch: ?i32 = null };

/// KickJS's `migrationsOnBoot`.
pub const OnBoot = enum { apply, fail_if_pending, ignore };

pub const Options = struct {
    /// Its lock table is `<table>_lock`.
    table: []const u8 = "kick_migrations",
    on_boot: OnBoot = .fail_if_pending,
    /// A lock older than this was left by a run that died: taken over.
    stale_lock_s: u32 = 600,
};

/// `sha256:<hex>` of `up|down|snapshot` (kick/db's `hashMigration`).
pub fn hashOf(up: []const u8, down: []const u8, snapshot: []const u8) [71]u8 {
    var h = Sha256.init(.{});
    h.update(up);
    h.update("|");
    h.update(down);
    h.update("|");
    h.update(snapshot);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    var out: [71]u8 = undefined;
    @memcpy(out[0..7], "sha256:");
    out[7..].* = std.fmt.bytesToHex(digest, .lower);
    return out;
}

/// The migrations under `dir`, in id order. `_journal.json` and other
/// files are not migrations.
pub fn load(io: Io, a: Allocator, dir_path: []const u8) ![]Migration {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var list: std.ArrayList(Migration) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '_' or entry.name[0] == '.') continue;
        const id = try a.dupe(u8, entry.name);
        var sub = try dir.openDir(io, id, .{});
        defer sub.close(io);
        const up = sub.readFileAlloc(io, "up.sql", a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                if (!builtin.is_test) std.log.err("migration {s}: no up.sql", .{id});
                return error.MissingUpSql;
            },
            else => return err,
        };
        const down = sub.readFileAlloc(io, "down.sql", a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        const snapshot = sub.readFileAlloc(io, "snapshot.json", a, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        try list.append(a, .{ .id = id, .name = nameOf(id), .up = up, .down = down, .hash = try a.dupe(u8, &hashOf(up, down, snapshot)) });
    }
    std.mem.sort(Migration, list.items, {}, struct {
        fn less(_: void, x: Migration, y: Migration) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.less);
    return list.items;
}

/// `20261015_231323_init` → `init`; any other id is its own name.
fn nameOf(id: []const u8) []const u8 {
    if (id.len > 16 and id[8] == '_' and id[15] == '_') {
        for (id[0..8]) |c| if (!std.ascii.isDigit(c)) return id;
        for (id[9..15]) |c| if (!std.ascii.isDigit(c)) return id;
        return id[16..];
    }
    return id;
}

/// `"schema"."table"`; only plain identifiers are accepted.
fn quoted(a: Allocator, name: []const u8) ![]const u8 {
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return error.InvalidTableName;
    const dot = std.mem.findScalar(u8, name, '.');
    if (dot) |i| return std.fmt.allocPrint(a, "\"{s}\".\"{s}\"", .{ name[0..i], name[i + 1 ..] });
    return std.fmt.allocPrint(a, "\"{s}\"", .{name});
}

const Tables = struct { t: []const u8, lock: []const u8 };

fn tablesOf(a: Allocator, o: Options) !Tables {
    return .{ .t = try quoted(a, o.table), .lock = try quoted(a, try std.mem.concat(a, u8, &.{ o.table, "_lock" })) };
}

fn ensure(pool: *db.Pool, a: Allocator, o: Options) !Tables {
    const tables = try tablesOf(a, o);
    const schema = if (std.mem.findScalar(u8, o.table, '.')) |i| try std.fmt.allocPrint(a, "CREATE SCHEMA IF NOT EXISTS \"{s}\";\n", .{o.table[0..i]}) else "";
    try pool.execScript(try std.fmt.allocPrint(a,
        \\{s}CREATE TABLE IF NOT EXISTS {s} (
        \\  "id" varchar(128) PRIMARY KEY,
        \\  "name" text NOT NULL,
        \\  "hash" text NOT NULL,
        \\  "batch" integer NOT NULL,
        \\  "applied_at" timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\  "direction" varchar(8) NOT NULL DEFAULT 'up'
        \\);
        \\CREATE TABLE IF NOT EXISTS {s} (
        \\  "id" smallint PRIMARY KEY,
        \\  "locked_at" timestamptz,
        \\  "locked_by" text
        \\);
        \\INSERT INTO {s} ("id") VALUES (1) ON CONFLICT DO NOTHING;
    , .{ schema, tables.t, tables.lock, tables.lock }));
    return tables;
}

const Applied = struct { id: []const u8, hash: []const u8, batch: i32 };

fn appliedRows(pool: *db.Pool, a: Allocator, tables: Tables) ![]Applied {
    return pool.query(a, Applied, try std.fmt.allocPrint(a, "SELECT id, hash, batch FROM {s} WHERE direction = 'up' ORDER BY id", .{tables.t}), .{});
}

fn find(rows: []const Applied, id: []const u8) ?Applied {
    for (rows) |r| if (std.mem.eql(u8, r.id, id)) return r;
    return null;
}

/// Each migration: applied, pending, or applied but edited since (`changed`).
/// Only reads: a production role without CREATE can check at boot, and
/// replicas booting together don't race to make the tables.
pub fn status(pool: *db.Pool, a: Allocator, list: []const Migration, o: Options) ![]Status {
    const tables = try tablesOf(a, o);
    const exists = try pool.queryOne(a, struct { t: ?[]const u8 }, "SELECT to_regclass($1)::text AS t", .{tables.t});
    const rows = if (exists.?.t == null) &.{} else try appliedRows(pool, a, tables);
    const out = try a.alloc(Status, list.len);
    for (list, out) |m, *s| {
        s.* = .{ .id = m.id, .name = m.name, .state = .pending };
        if (find(rows, m.id)) |r| s.* = .{ .id = m.id, .name = m.name, .state = if (std.mem.eql(u8, r.hash, m.hash)) .applied else .changed, .batch = r.batch };
    }
    return out;
}

/// One run's hold on the lock table. Each run has its own name, so a run
/// whose stale lock was taken over can tell, and can't release the new one.
const Lock = struct {
    pool: *db.Pool,
    tables: Tables,
    owner: []const u8,
    keep_sql: []const u8,

    fn take(pool: *db.Pool, a: Allocator, tables: Tables, o: Options) !Lock {
        var id: [8]u8 = undefined;
        pool.io.random(&id);
        const l: Lock = .{
            .pool = pool,
            .tables = tables,
            .owner = try std.fmt.allocPrint(a, "kzig:{x}", .{id}),
            .keep_sql = try std.fmt.allocPrint(a, "UPDATE {s} SET locked_at = CURRENT_TIMESTAMP WHERE id = 1 AND locked_by = $1", .{tables.lock}),
        };
        const taken = try pool.exec(try std.fmt.allocPrint(a,
            \\UPDATE {s} SET locked_at = CURRENT_TIMESTAMP, locked_by = $1
            \\WHERE id = 1 AND (locked_at IS NULL OR locked_at < CURRENT_TIMESTAMP - make_interval(secs => $2))
        , .{tables.lock}), .{ l.owner, o.stale_lock_s });
        if (taken != 1) return held(tables);
        return l;
    }

    /// Before each migration: still ours, and fresh again.
    fn keep(l: Lock) !void {
        // ponytail: refreshed between migrations, not during one; a single
        // migration longer than stale_lock_s can still be taken over.
        if (try l.pool.exec(l.keep_sql, .{l.owner}) != 1) return held(l.tables);
    }

    fn release(l: Lock, a: Allocator) void {
        const sql = std.fmt.allocPrint(a, "UPDATE {s} SET locked_at = NULL, locked_by = NULL WHERE id = 1 AND locked_by = $1", .{l.tables.lock}) catch return;
        _ = l.pool.exec(sql, .{l.owner}) catch {};
    }

    fn held(tables: Tables) error{MigrationLocked} {
        if (!builtin.is_test) std.log.err("migrations: another run holds {s}", .{tables.lock});
        return error.MigrationLocked;
    }
};

fn refuseChanged(list: []const Migration, rows: []const Applied) !void {
    for (list) |m| if (find(rows, m.id)) |r| if (!std.mem.eql(u8, r.hash, m.hash)) {
        if (!builtin.is_test) std.log.err("migration {s} was applied and has been edited since; add a new migration instead", .{m.id});
        return error.MigrationChanged;
    };
}

pub const Result = struct { applied: usize, batch: i32 };

/// Every pending migration, in order, as one batch (kick/db `migrate
/// latest`). A failure stops the run; what it changed is rolled back.
pub fn latest(pool: *db.Pool, a: Allocator, list: []const Migration, o: Options) !Result {
    const tables = try ensure(pool, a, o);
    const l: Lock = try .take(pool, a, tables, o);
    defer l.release(a);
    const rows = try appliedRows(pool, a, tables);
    try refuseChanged(list, rows);
    var batch: i32 = 0;
    for (rows) |r| batch = @max(batch, r.batch);
    batch += 1;
    const insert = try std.fmt.allocPrint(a, "INSERT INTO {s} (id, name, hash, batch, direction) VALUES ($1, $2, $3, $4, 'up')", .{tables.t});
    var count: usize = 0;
    for (list) |m| {
        if (find(rows, m.id) != null) continue;
        try l.keep();
        var tx = try pool.begin();
        defer tx.deinit();
        tx.execScript(m.up) catch |err| {
            if (!builtin.is_test) std.log.err("migration {s} failed; rolled back", .{m.id});
            return err;
        };
        _ = try tx.exec(insert, .{ m.id, m.name, m.hash, batch });
        try tx.commit();
        count += 1;
        if (!builtin.is_test) std.log.info("migration {s} applied", .{m.id});
    }
    return .{ .applied = count, .batch = if (count > 0) batch else batch - 1 };
}

/// The last batch, newest first, through each `down.sql`.
pub fn rollback(pool: *db.Pool, a: Allocator, list: []const Migration, o: Options) !usize {
    const tables = try ensure(pool, a, o);
    const l: Lock = try .take(pool, a, tables, o);
    defer l.release(a);
    const rows = try appliedRows(pool, a, tables);
    var last: i32 = 0;
    for (rows) |r| last = @max(last, r.batch);
    if (last == 0) return 0;
    const delete = try std.fmt.allocPrint(a, "DELETE FROM {s} WHERE id = $1", .{tables.t});
    var count: usize = 0;
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        const r = rows[i];
        if (r.batch != last) continue;
        const m = for (list) |m| {
            if (std.mem.eql(u8, m.id, r.id)) break m;
        } else return error.MigrationMissing;
        if (m.down.len == 0) {
            if (!builtin.is_test) std.log.err("migration {s} has no down.sql", .{m.id});
            return error.NoDownMigration;
        }
        try l.keep();
        var tx = try pool.begin();
        defer tx.deinit();
        try tx.execScript(m.down);
        _ = try tx.exec(delete, .{m.id});
        try tx.commit();
        count += 1;
    }
    return count;
}

/// What an app does at boot (KickJS's `kickDbAdapter`): apply pending
/// migrations, or refuse to start while any are pending.
pub fn onBoot(pool: *db.Pool, io: Io, gpa: Allocator, dir: []const u8, o: Options) !void {
    if (o.on_boot == .ignore) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try load(io, a, dir);
    switch (o.on_boot) {
        .ignore => {},
        .apply => _ = try latest(pool, a, list, o),
        .fail_if_pending => {
            var pending: usize = 0;
            for (try status(pool, a, list, o)) |s| switch (s.state) {
                .pending => {
                    pending += 1;
                    if (!builtin.is_test) std.log.err("migration {s} is pending", .{s.id});
                },
                .changed => return error.MigrationChanged,
                .applied => {},
            };
            if (pending > 0) {
                if (!builtin.is_test) std.log.err("{d} pending migration(s): run them before starting (kzig db migrate)", .{pending});
                return error.PendingMigrations;
            }
        },
    }
}

const testing = std.testing;

const TmpMigrations = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,

    fn init() !TmpMigrations {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    }

    fn deinit(t: *TmpMigrations) void {
        testing.allocator.free(t.path);
        t.tmp.cleanup();
    }

    fn add(t: *TmpMigrations, id: []const u8, up: []const u8, down: []const u8) !void {
        try t.tmp.dir.createDirPath(testing.io, id);
        var buf: [256]u8 = undefined;
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/up.sql", .{id}), .data = up });
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/down.sql", .{id}), .data = down });
    }
};

const opts: Options = .{ .table = "kzig_test_migrations" };

fn reset(pool: *db.Pool) !void {
    try pool.execScript("DROP TABLE IF EXISTS kzig_test_migrations, kzig_test_migrations_lock, kzig_m_a, kzig_m_b, kzig_m_c");
}

test "hash: sha256 of up|down|snapshot, as kick/db records it" {
    // python3 -c "import hashlib; print(hashlib.sha256(b'CREATE TABLE t (id int);|DROP TABLE t;|').hexdigest())"
    const h = hashOf("CREATE TABLE t (id int);", "DROP TABLE t;", "");
    try testing.expectEqualStrings("sha256:83e990a1bbb75fe706d065bac55f684565c6babd18cdb28b2df8e91c590f13e9", &h);
}

test "ids, names and order come from the folders" {
    var m = try TmpMigrations.init();
    defer m.deinit();
    try m.add("20261015_231323_init", "SELECT 1;", "");
    try m.add("20261016_090000_add_tasks", "SELECT 2;", "SELECT 3;");
    try m.tmp.dir.writeFile(testing.io, .{ .sub_path = "_journal.json", .data = "{}" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try load(testing.io, arena.allocator(), m.path);
    try testing.expectEqual(2, list.len);
    try testing.expectEqualStrings("20261015_231323_init", list[0].id);
    try testing.expectEqualStrings("init", list[0].name);
    try testing.expectEqualStrings("add_tasks", list[1].name);
    try testing.expectEqualStrings("SELECT 3;", list[1].down);
    try testing.expect(std.mem.startsWith(u8, list[0].hash, "sha256:"));
}

test "latest applies pending migrations in one batch; status and rollback follow" {
    var env: std.process.Environ.Map = undefined;
    const url = db.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try reset(&pool);
    defer reset(&pool) catch {};
    var m = try TmpMigrations.init();
    defer m.deinit();
    try m.add("20260101_000000_a", "CREATE TABLE kzig_m_a (id int);", "DROP TABLE kzig_m_a;");
    try m.add("20260102_000000_b", "CREATE TABLE kzig_m_b (id int); INSERT INTO kzig_m_b VALUES (1);", "DROP TABLE kzig_m_b;");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var list = try load(testing.io, a, m.path);
    for (try status(&pool, a, list, opts)) |s| try testing.expectEqual(.pending, s.state);
    const first = try latest(&pool, a, list, opts);
    try testing.expectEqual(2, first.applied);
    try testing.expectEqual(1, first.batch);
    for (try status(&pool, a, list, opts)) |s| try testing.expectEqual(.applied, s.state);
    try testing.expectEqual(1, (try pool.queryOne(a, struct { n: i64 }, "SELECT count(*) AS n FROM kzig_m_b", .{})).?.n);
    try testing.expectEqual(0, (try latest(&pool, a, list, opts)).applied);

    try m.add("20260103_000000_c", "CREATE TABLE kzig_m_c (id int);", "DROP TABLE kzig_m_c;");
    list = try load(testing.io, a, m.path);
    try testing.expectEqual(2, (try latest(&pool, a, list, opts)).batch);
    // Rollback undoes the last batch only.
    try testing.expectEqual(1, try rollback(&pool, a, list, opts));
    const after = try status(&pool, a, list, opts);
    try testing.expectEqual(.applied, after[1].state);
    try testing.expectEqual(.pending, after[2].state);
    try testing.expectError(error.DbError, pool.exec("SELECT * FROM kzig_m_c", .{}));
}

test "a failing migration leaves nothing behind; an edited one stops the run" {
    var env: std.process.Environ.Map = undefined;
    const url = db.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try reset(&pool);
    defer reset(&pool) catch {};
    var m = try TmpMigrations.init();
    defer m.deinit();
    try m.add("20260101_000000_a", "CREATE TABLE kzig_m_a (id int);", "DROP TABLE kzig_m_a;");
    try m.add("20260102_000000_b", "CREATE TABLE kzig_m_b (id int); SELECT nonsense FROM nowhere;", "DROP TABLE kzig_m_b;");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.DbError, latest(&pool, a, try load(testing.io, a, m.path), opts));
    // a went in (its own transaction); b, and its table, did not.
    const st = try status(&pool, a, try load(testing.io, a, m.path), opts);
    try testing.expectEqual(.applied, st[0].state);
    try testing.expectEqual(.pending, st[1].state);
    try testing.expectError(error.DbError, pool.exec("SELECT * FROM kzig_m_b", .{}));

    // Edit an applied migration: status says so and nothing runs.
    try m.add("20260101_000000_a", "CREATE TABLE kzig_m_a (id bigint);", "DROP TABLE kzig_m_a;");
    const edited = try load(testing.io, a, m.path);
    try testing.expectEqual(.changed, (try status(&pool, a, edited, opts))[0].state);
    try testing.expectError(error.MigrationChanged, latest(&pool, a, edited, opts));
}

test "status only reads: no bookkeeping tables are made" {
    var env: std.process.Environ.Map = undefined;
    const url = db.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try reset(&pool);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]Migration{.{ .id = "20260101_000000_a", .name = "a", .up = "", .down = "", .hash = "sha256:x" }};
    const states = try status(&pool, a, &list, opts);
    try testing.expectEqual(State.pending, states[0].state);
    const t = try pool.queryOne(a, struct { t: ?[]const u8 }, "SELECT to_regclass('kzig_test_migrations')::text AS t", .{});
    try testing.expectEqual(null, t.?.t);
}

test "a run that loses the lock stops, and leaves the new holder's lock alone" {
    var env: std.process.Environ.Map = undefined;
    const url = db.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try reset(&pool);
    defer reset(&pool) catch {};
    var m = try TmpMigrations.init();
    defer m.deinit();
    // The first migration plays a second run taking the lock over as stale.
    try m.add("20260101_000000_a", "UPDATE kzig_test_migrations_lock SET locked_by = 'other', locked_at = now() WHERE id = 1;", "");
    try m.add("20260101_000001_b", "CREATE TABLE kzig_m_b (id int);", "DROP TABLE kzig_m_b;");
    var o = opts;
    o.on_boot = .apply;
    try testing.expectError(error.MigrationLocked, onBoot(&pool, testing.io, testing.allocator, m.path, o));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const held = try pool.queryOne(arena.allocator(), struct { locked_by: ?[]const u8 }, "SELECT locked_by FROM kzig_test_migrations_lock", .{});
    try testing.expectEqualStrings("other", held.?.locked_by.?);
    const b = try pool.queryOne(arena.allocator(), struct { t: ?[]const u8 }, "SELECT to_regclass('kzig_m_b')::text AS t", .{});
    try testing.expectEqual(null, b.?.t);
}

test "boot policy and the lock" {
    var env: std.process.Environ.Map = undefined;
    const url = db.testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try reset(&pool);
    defer reset(&pool) catch {};
    var m = try TmpMigrations.init();
    defer m.deinit();
    try m.add("20260101_000000_a", "CREATE TABLE kzig_m_a (id int);", "DROP TABLE kzig_m_a;");

    var o = opts;
    o.on_boot = .fail_if_pending;
    try testing.expectError(error.PendingMigrations, onBoot(&pool, testing.io, testing.allocator, m.path, o));
    // Another run holds the lock.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try ensure(&pool, arena.allocator(), opts);
    _ = try pool.exec("UPDATE kzig_test_migrations_lock SET locked_at = now(), locked_by = 'someone' WHERE id = 1", .{});
    o.on_boot = .apply;
    try testing.expectError(error.MigrationLocked, onBoot(&pool, testing.io, testing.allocator, m.path, o));
    _ = try pool.exec("UPDATE kzig_test_migrations_lock SET locked_at = NULL, locked_by = NULL WHERE id = 1", .{});
    try onBoot(&pool, testing.io, testing.allocator, m.path, o);
    o.on_boot = .fail_if_pending;
    try onBoot(&pool, testing.io, testing.allocator, m.path, o);
}
