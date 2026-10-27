//! `kzig.db`: PostgreSQL through a pool, parameterised SQL decoded into
//! structs, transactions; migrations in `migrate.zig`. The kick/db query
//! builder and schema are later milestones; this is the layer under them.
//!
//! ```zig
//! var db: kzig.db.Pool = try .init(io, gpa, .{ .url = settings.database_url.? });
//! defer db.deinit();
//! const users = try db.query(arena, User, "SELECT id, email FROM users WHERE email = $1", .{email});
//! var tx = try db.begin();
//! defer tx.deinit(); // rolls back unless committed
//! _ = try tx.exec("UPDATE users SET name = $1 WHERE id = $2", .{ name, id });
//! try tx.commit();
//! ```
const std = @import("std");
pub const pg = @import("pg.zig");
pub const migrate = @import("migrate.zig");
pub const Timestamp = @import("timestamp.zig").Timestamp;
const schema_ = @import("schema.zig");
pub const table = schema_.table;
pub const Schema = schema_.Schema;
pub const Column = schema_.Column;
const query_ = @import("query.zig");
pub const snapshot = @import("snapshot.zig");
pub const diff = @import("diff.zig");
pub const Client = query_.Client;
pub const eq = query_.eq;
pub const ne = query_.ne;
pub const gt = query_.gt;
pub const gte = query_.gte;
pub const lt = query_.lt;
pub const lte = query_.lte;
pub const like = query_.like;
pub const notLike = query_.notLike;
pub const ilike = query_.ilike;
pub const isNull = query_.isNull;
pub const isNotNull = query_.isNotNull;
pub const inArray = query_.inArray;
pub const notInArray = query_.notInArray;
pub const between = query_.between;
pub const all = query_.all;
pub const any = query_.any;
pub const not = query_.not;
pub const exists = query_.exists;
pub const sql = query_.sql;
pub const escapeLike = query_.escapeLike;

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `DATABASE_URL`, as the archive apps read it.
pub const Settings = struct {
    database_url: ?[]const u8 = null,
};

pub const Options = struct {
    /// `postgres://user:password@host:5432/database`.
    url: []const u8,
    max_connections: u32 = 10,
    /// Server-side; 0 leaves the server's default.
    statement_timeout_ms: u32 = 0,
};

/// Connections made as needed, up to `max_connections`; a task waits for
/// one beyond that. A broken connection, or one left inside a transaction,
/// is closed instead of reused.
pub const Pool = struct {
    io: Io,
    gpa: Allocator,
    config: pg.Config,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    idle: std.ArrayList(*pg.Conn) = .empty,
    permits: Io.Semaphore,

    pub fn init(io: Io, gpa: Allocator, o: Options) !Pool {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var config = try pg.Config.parse(a, try a.dupe(u8, o.url));
        config.statement_timeout_ms = o.statement_timeout_ms;
        return .{ .io = io, .gpa = gpa, .config = config, .arena = arena, .permits = .{ .permits = o.max_connections } };
    }

    /// Every connection must have been released.
    pub fn deinit(p: *Pool) void {
        for (p.idle.items) |c| c.close();
        p.idle.deinit(p.gpa);
        p.arena.deinit();
    }

    fn acquire(p: *Pool) !*pg.Conn {
        p.permits.wait(p.io) catch return error.ServiceUnavailable;
        errdefer p.permits.post(p.io);
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            if (p.idle.pop()) |c| return c;
        }
        return pg.Conn.connect(p.io, p.gpa, p.config);
    }

    fn release(p: *Pool, c: *pg.Conn) void {
        defer p.permits.post(p.io);
        if (c.broken or c.tx_status != 'I') return c.close();
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        p.idle.append(p.gpa, c) catch c.close();
    }

    /// Every row of `text` as a `T`, by column name; strings in `a`.
    pub fn query(p: *Pool, a: Allocator, comptime T: type, text: []const u8, args: anytype) ![]T {
        const c = try p.acquire();
        defer p.release(c);
        return queryOn(c, a, T, text, args);
    }

    /// The first row, or null.
    pub fn queryOne(p: *Pool, a: Allocator, comptime T: type, text: []const u8, args: anytype) !?T {
        const rows = try p.query(a, T, text, args);
        return if (rows.len > 0) rows[0] else null;
    }

    /// Rows affected (INSERT, UPDATE, DELETE).
    pub fn exec(p: *Pool, text: []const u8, args: anytype) !u64 {
        const c = try p.acquire();
        defer p.release(c);
        return execOn(c, text, args);
    }

    /// `query` with parameters already encoded (the query builder's).
    pub fn queryParams(p: *Pool, a: Allocator, comptime T: type, text: []const u8, params: []const ?[]const u8) ![]T {
        const c = try p.acquire();
        defer p.release(c);
        return rowsOn(c, a, T, text, params);
    }

    pub fn execParams(p: *Pool, text: []const u8, params: []const ?[]const u8) !u64 {
        const c = try p.acquire();
        defer p.release(c);
        return c.run(text, params, {}, ignoreRow);
    }

    /// Several statements, no parameters (a migration).
    pub fn execScript(p: *Pool, text: []const u8) !void {
        const c = try p.acquire();
        defer p.release(c);
        return c.script(text);
    }

    /// `SELECT 1`: for `/health/ready`.
    pub fn ping(p: *Pool) !void {
        _ = try p.exec("SELECT 1", .{});
    }

    pub fn begin(p: *Pool) !Tx {
        const c = try p.acquire();
        errdefer p.release(c);
        try c.script("BEGIN");
        return .{ .pool = p, .conn = c };
    }
};

/// One connection inside `BEGIN`. `deinit` rolls back unless `commit` ran.
pub const Tx = struct {
    pool: *Pool,
    conn: ?*pg.Conn,

    pub fn query(t: *Tx, a: Allocator, comptime T: type, text: []const u8, args: anytype) ![]T {
        return queryOn(t.conn orelse return error.TransactionDone, a, T, text, args);
    }

    pub fn queryOne(t: *Tx, a: Allocator, comptime T: type, text: []const u8, args: anytype) !?T {
        const rows = try t.query(a, T, text, args);
        return if (rows.len > 0) rows[0] else null;
    }

    pub fn exec(t: *Tx, text: []const u8, args: anytype) !u64 {
        return execOn(t.conn orelse return error.TransactionDone, text, args);
    }

    pub fn execScript(t: *Tx, text: []const u8) !void {
        return (t.conn orelse return error.TransactionDone).script(text);
    }

    pub fn queryParams(t: *Tx, a: Allocator, comptime T: type, text: []const u8, params: []const ?[]const u8) ![]T {
        return rowsOn(t.conn orelse return error.TransactionDone, a, T, text, params);
    }

    pub fn execParams(t: *Tx, text: []const u8, params: []const ?[]const u8) !u64 {
        return (t.conn orelse return error.TransactionDone).run(text, params, {}, ignoreRow);
    }

    pub fn commit(t: *Tx) !void {
        const c = t.conn orelse return error.TransactionDone;
        t.conn = null;
        defer t.pool.release(c);
        // After a failed statement Postgres answers COMMIT with a rollback
        // and no error; the caller must hear its writes are gone.
        if (c.tx_status == 'E') {
            c.script("ROLLBACK") catch {};
            return error.TransactionAborted;
        }
        try c.script("COMMIT");
    }

    pub fn rollback(t: *Tx) void {
        const c = t.conn orelse return;
        t.conn = null;
        defer t.pool.release(c);
        c.script("ROLLBACK") catch {};
    }

    pub fn deinit(t: *Tx) void {
        t.rollback();
    }
};

fn queryOn(c: *pg.Conn, a: Allocator, comptime T: type, text: []const u8, args: anytype) ![]T {
    return rowsOn(c, a, T, text, try pg.encodeArgs(a, args));
}

fn ignoreRow(_: void, _: []const []const u8, _: []const ?[]const u8) !void {}

fn rowsOn(c: *pg.Conn, a: Allocator, comptime T: type, text: []const u8, params: []const ?[]const u8) ![]T {
    if (@typeInfo(T) != .@"struct") @compileError("db: rows decode into a struct, not " ++ @typeName(T));
    const Rows = struct {
        a: Allocator,
        list: std.ArrayList(T) = .empty,

        fn add(self: *@This(), names: []const []const u8, values: []const ?[]const u8) !void {
            try self.list.append(self.a, try pg.decodeRow(T, self.a, names, values));
        }
    };
    var rows: Rows = .{ .a = a };
    _ = try c.run(text, params, &rows, Rows.add);
    return rows.list.items;
}

fn execOn(c: *pg.Conn, text: []const u8, args: anytype) !u64 {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var arena: std.heap.ArenaAllocator = .init(fba.allocator());
    return c.run(text, try pg.encodeArgs(arena.allocator(), args), {}, ignoreRow);
}

const testing = std.testing;

test {
    _ = migrate;
    _ = @import("timestamp.zig");
    _ = schema_;
    _ = query_;
    _ = snapshot;
    _ = diff;
    _ = pg;
}

/// `DATABASE_URL` for the tests that need a server; skipped without one.
pub fn testUrl(buf: *std.process.Environ.Map) ![]const u8 {
    buf.* = try testing.environ.createMap(testing.allocator);
    return buf.get("DATABASE_URL") orelse error.SkipZigTest;
}

const Person = struct { id: i64, name: []const u8, email: ?[]const u8, active: bool };

test "query, queryOne and exec: typed rows, parameters, NULL" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try db.execScript("DROP TABLE IF EXISTS kzig_people; CREATE TABLE kzig_people (id bigserial PRIMARY KEY, name text NOT NULL, email text UNIQUE, active boolean NOT NULL DEFAULT true)");
    defer db.execScript("DROP TABLE kzig_people") catch {};
    try testing.expectEqual(1, try db.exec("INSERT INTO kzig_people (name, email) VALUES ($1, $2)", .{ "Ada", "ada@example.com" }));
    try testing.expectEqual(1, try db.exec("INSERT INTO kzig_people (name, email, active) VALUES ($1, $2, $3)", .{ "Bo", @as(?[]const u8, null), false }));

    const people = try db.query(a, Person, "SELECT id, name, email, active FROM kzig_people ORDER BY id", .{});
    try testing.expectEqual(2, people.len);
    try testing.expectEqualStrings("Ada", people[0].name);
    try testing.expectEqualStrings("ada@example.com", people[0].email.?);
    try testing.expectEqual(null, people[1].email);
    try testing.expect(!people[1].active);

    const one = (try db.queryOne(a, Person, "SELECT * FROM kzig_people WHERE name = $1", .{"Bo"})).?;
    try testing.expectEqualStrings("Bo", one.name);
    try testing.expectEqual(null, try db.queryOne(a, Person, "SELECT * FROM kzig_people WHERE name = $1", .{"nobody"}));
    try testing.expectEqual(2, try db.exec("UPDATE kzig_people SET active = $1", .{true}));

    // Wide values come through whole.
    const Wide = struct { s: []const u8 };
    const wide = (try db.queryOne(a, Wide, "SELECT repeat('x', 100000) AS s", .{})).?;
    try testing.expectEqual(100000, wide.s.len);
}

test "errors: a unique violation is Conflict, others DbError; the pool carries on" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer db.deinit();
    try db.execScript("DROP TABLE IF EXISTS kzig_uniq; CREATE TABLE kzig_uniq (email text PRIMARY KEY)");
    defer db.execScript("DROP TABLE kzig_uniq") catch {};
    _ = try db.exec("INSERT INTO kzig_uniq VALUES ($1)", .{"a@example.com"});
    try testing.expectError(error.Conflict, db.exec("INSERT INTO kzig_uniq VALUES ($1)", .{"a@example.com"}));
    try testing.expectError(error.DbError, db.exec("SELEC nonsense", .{}));
    // Missing column for the struct.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.DbDecode, db.query(arena.allocator(), struct { nope: i32 }, "SELECT 1 AS yes", .{}));
    // Same one connection, still fine.
    try db.ping();
}

test "transactions: commit keeps, rollback and an unfinished one discard" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 2 });
    defer db.deinit();
    try db.execScript("DROP TABLE IF EXISTS kzig_tx; CREATE TABLE kzig_tx (n int)");
    defer db.execScript("DROP TABLE kzig_tx") catch {};
    {
        var tx = try db.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_tx VALUES ($1)", .{1});
        try tx.commit();
    }
    {
        var tx = try db.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_tx VALUES ($1)", .{2});
        tx.rollback();
    }
    {
        var tx = try db.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_tx VALUES ($1)", .{3});
        // No commit: deinit rolls back.
    }
    {
        // An error inside rolls the whole transaction back.
        var tx = try db.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_tx VALUES ($1)", .{4});
        try testing.expectError(error.DbError, tx.exec("INSERT INTO kzig_tx VALUES ($1)", .{"not a number"}));
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try db.query(arena.allocator(), struct { n: i32 }, "SELECT n FROM kzig_tx ORDER BY n", .{});
    try testing.expectEqual(1, rows.len);
    try testing.expectEqual(1, rows[0].n);
}

test "a row wider than the decoder takes is DbDecode, and the connection stays in step" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer db.deinit();
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(testing.allocator);
    try wide.appendSlice(testing.allocator, "SELECT 1 AS c0");
    for (1..70) |i| try wide.print(testing.allocator, ", 1 AS c{d}", .{i});
    try testing.expectError(error.DbDecode, db.exec(wide.items, .{}));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const row = try db.queryOne(arena.allocator(), struct { x: i32 }, "SELECT 42 AS x", .{});
    try testing.expectEqual(42, row.?.x);
}

test "committing after a failed statement is an error, not a silent rollback" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer db.deinit();
    var tx = try db.begin();
    defer tx.deinit();
    try testing.expectError(error.DbError, tx.exec("SELEC nonsense", .{}));
    try testing.expectError(error.TransactionAborted, tx.commit());
    try db.ping();
}

test "sessions run in UTC with ISO dates, whatever the server's defaults" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = (try db.queryOne(arena.allocator(), struct { tz: []const u8, ds: []const u8 }, "SELECT current_setting('TimeZone') AS tz, current_setting('DateStyle') AS ds", .{})).?;
    try testing.expectEqualStrings("UTC", r.tz);
    try testing.expectEqualStrings("ISO, MDY", r.ds);
}

test "Timestamp round-trips through timestamptz and timestamp" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 1 });
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at: Timestamp = .{ .us = 1793091600500001 };
    const R = struct { tz: Timestamp, plain: Timestamp, day: Timestamp };
    const r = (try db.queryOne(arena.allocator(), R, "SELECT $1::timestamptz AS tz, $1::timestamptz AT TIME ZONE 'UTC' AS plain, '2026-10-27'::date AS day", .{at})).?;
    try testing.expectEqual(at.us, r.tz.us);
    try testing.expectEqual(at.us, r.plain.us);
    try testing.expectEqual(1793059200000000, r.day.us);
}

test "the pool: more tasks than connections, all served" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var db: Pool = try .init(testing.io, testing.allocator, .{ .url = url, .max_connections = 2 });
    defer db.deinit();
    const Task = struct {
        fn run(p: *Pool, failed: *std.atomic.Value(u32)) void {
            _ = p.exec("SELECT pg_sleep(0.05)", .{}) catch {
                _ = failed.fetchAdd(1, .acq_rel);
            };
        }
    };
    var failed: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..8) |_| try group.concurrent(testing.io, Task.run, .{ &db, &failed });
    try group.await(testing.io);
    try testing.expectEqual(0, failed.load(.acquire));
    try testing.expect(db.idle.items.len <= 2);
}

test "connecting: a wrong password, a server that isn't there" {
    var env: std.process.Environ.Map = undefined;
    const url = testUrl(&env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var cfg = try pg.Config.parse(arena.allocator(), url);
    cfg.password = "wrong";
    try testing.expectError(error.DbAuthFailed, pg.Conn.connect(testing.io, testing.allocator, cfg));
    cfg.port = 1;
    try testing.expectError(error.ServiceUnavailable, pg.Conn.connect(testing.io, testing.allocator, cfg));
    // A host name is looked up, not only an IP literal.
    cfg = try pg.Config.parse(arena.allocator(), url);
    if (std.mem.eql(u8, cfg.host, "127.0.0.1")) cfg.host = "localhost";
    const c = try pg.Conn.connect(testing.io, testing.allocator, cfg);
    c.close();
}

test "database URLs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try pg.Config.parse(a, "postgres://ada:p%40ss@db.example.com:6543/app?application_name=api");
    try testing.expectEqualStrings("ada", c.user);
    try testing.expectEqualStrings("p@ss", c.password);
    try testing.expectEqualStrings("db.example.com", c.host);
    try testing.expectEqual(6543, c.port);
    try testing.expectEqualStrings("app", c.database);
    try testing.expectEqualStrings("api", c.application_name);
    try testing.expectEqualStrings("ada", (try pg.Config.parse(a, "postgresql://ada@localhost")).database);
    try testing.expectError(error.TlsNotSupported, pg.Config.parse(a, "postgres://ada@h/app?sslmode=require"));
    try testing.expectError(error.InvalidDatabaseUrl, pg.Config.parse(a, "mysql://ada@h/app"));
}
