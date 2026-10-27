//! Local SQLite files (`sqlite:./app.db`, `sqlite::memory:`) through SQLite's
//! C library, built only with `-Dsqlite`.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("sqlite3");
const pg = @import("pg.zig");

const Allocator = std.mem.Allocator;
const Error = pg.Error;

/// One database handle. Not shared: the pool hands it to one task at a time.
pub const Conn = struct {
    handle: *c.sqlite3,
    gpa: Allocator,
    /// Tests' fake D1 binds as D1 does: these params as integers, the rest
    /// as text (instead of the canonical-integer rule).
    ints: ?[]const bool = null,

    /// `path` as SQLite takes it: a file, or `:memory:`.
    pub fn open(gpa: Allocator, path: []const u8) !*Conn {
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        var h: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(z.ptr, &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
        if (rc != c.SQLITE_OK) {
            if (!builtin.is_test) std.log.err("db: sqlite {s}: {s}", .{ path, std.mem.span(c.sqlite3_errstr(rc)) });
            _ = c.sqlite3_close(h);
            return error.ServiceUnavailable;
        }
        const conn = gpa.create(Conn) catch |err| {
            _ = c.sqlite3_close(h);
            return err;
        };
        conn.* = .{ .handle = h.?, .gpa = gpa };
        errdefer conn.close();
        // Writers wait for each other instead of failing with SQLITE_BUSY.
        _ = c.sqlite3_busy_timeout(conn.handle, 5000);
        try conn.script("PRAGMA foreign_keys = ON");
        if (!std.mem.eql(u8, path, ":memory:")) try conn.script("PRAGMA journal_mode = WAL");
        return conn;
    }

    pub fn close(conn: *Conn) void {
        _ = c.sqlite3_close_v2(conn.handle);
        conn.gpa.destroy(conn);
    }

    /// The last error's text (tests' fake D1 answers with it).
    pub fn lastError(conn: *Conn) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(conn.handle));
    }

    /// Inside BEGIN … COMMIT.
    pub fn inTransaction(conn: *Conn) bool {
        return c.sqlite3_get_autocommit(conn.handle) == 0;
    }

    /// One statement; each row to `row(ctx, names, values)`. Rows read for a
    /// query, rows changed otherwise.
    pub fn run(conn: *Conn, sql: []const u8, params: []const ?[]const u8, ctx: anytype, comptime row: anytype) Error!u64 {
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (c.sqlite3_prepare_v2(conn.handle, sql.ptr, @intCast(sql.len), &stmt, &tail) != c.SQLITE_OK) return conn.fail();
        const st = stmt orelse return 0; // only whitespace or a comment
        defer _ = c.sqlite3_finalize(st);
        // One statement, as Postgres's extended protocol takes: a second one
        // would otherwise be dropped without a word.
        if (!onlyTrivia(sql[@intFromPtr(tail) - @intFromPtr(sql.ptr) ..])) {
            if (!builtin.is_test) std.log.err("db: sqlite: one statement per query; use execScript for several", .{});
            return error.DbError;
        }
        const before = c.sqlite3_total_changes64(conn.handle);
        if (c.sqlite3_bind_parameter_count(st) != params.len) {
            if (!builtin.is_test) std.log.err("db: sqlite: {d} parameters for {d} placeholders", .{ params.len, c.sqlite3_bind_parameter_count(st) });
            return error.DbError;
        }
        for (params, 1..) |param, i| {
            const at: c_int = @intCast(i);
            // The params are alive until the statement is finalized: no copy.
            const rc = if (param) |v|
                (if ((if (conn.ints) |ints| (if (ints[i - 1]) canonicalInt(v) else null) else canonicalInt(v))) |n| c.sqlite3_bind_int64(st, at, n) else c.sqlite3_bind_text64(st, at, v.ptr, v.len, null, c.SQLITE_UTF8))
            else
                c.sqlite3_bind_null(st, at);
            if (rc != c.SQLITE_OK) return conn.fail();
        }
        const ncol: usize = @intCast(c.sqlite3_column_count(st));
        const names = try conn.gpa.alloc([]const u8, ncol);
        defer conn.gpa.free(names);
        const values = try conn.gpa.alloc(?[]const u8, ncol);
        defer conn.gpa.free(values);
        var rows: u64 = 0;
        while (true) switch (c.sqlite3_step(st)) {
            c.SQLITE_ROW => {
                // After the first step: it may re-prepare the statement (bound
                // values feed the planner), which frees earlier names.
                if (rows == 0) for (names, 0..) |*n, i| {
                    n.* = std.mem.span(c.sqlite3_column_name(st, @intCast(i)));
                };
                for (values, 0..) |*v, i| {
                    const col: c_int = @intCast(i);
                    v.* = switch (c.sqlite3_column_type(st, col)) {
                        c.SQLITE_NULL => null,
                        c.SQLITE_BLOB => bytes(c.sqlite3_column_blob(st, col), c.sqlite3_column_bytes(st, col)),
                        // Integers and reals as SQLite prints them.
                        else => bytes(c.sqlite3_column_text(st, col), c.sqlite3_column_bytes(st, col)),
                    };
                }
                try row(ctx, names, values);
                rows += 1;
            },
            c.SQLITE_DONE => break,
            else => return conn.fail(),
        };
        if (c.sqlite3_stmt_readonly(st) != 0) return rows;
        // DDL changes no rows; sqlite3_changes would repeat the last DML's count.
        return if (c.sqlite3_total_changes64(conn.handle) == before) 0 else @intCast(c.sqlite3_changes64(conn.handle));
    }

    /// Several statements, no parameters.
    pub fn script(conn: *Conn, sql: []const u8) Error!void {
        const z = try conn.gpa.dupeSentinel(u8, sql, 0);
        defer conn.gpa.free(z);
        if (c.sqlite3_exec(conn.handle, z.ptr, null, null, null) != c.SQLITE_OK) return conn.fail();
    }

    fn fail(conn: *Conn) Error {
        const code = c.sqlite3_extended_errcode(conn.handle);
        if (!builtin.is_test) std.log.err("db: sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(conn.handle))});
        return switch (code) {
            c.SQLITE_CONSTRAINT_UNIQUE, c.SQLITE_CONSTRAINT_PRIMARYKEY => error.Conflict,
            c.SQLITE_NOMEM => error.OutOfMemory,
            else => if (code & 0xff == c.SQLITE_BUSY or code & 0xff == c.SQLITE_IOERR) error.ServiceUnavailable else error.DbError,
        };
    }
};

/// Whitespace, `;` and comments only.
fn onlyTrivia(rest: []const u8) bool {
    var i: usize = 0;
    while (i < rest.len) {
        const ch = rest[i];
        if (std.ascii.isWhitespace(ch) or ch == ';') {
            i += 1;
        } else if (std.mem.startsWith(u8, rest[i..], "--")) {
            i = std.mem.findScalarPos(u8, rest, i, '\n') orelse rest.len;
        } else if (std.mem.startsWith(u8, rest[i..], "/*")) {
            i = if (std.mem.findPos(u8, rest, i + 2, "*/")) |e| e + 2 else rest.len;
        } else return false;
    }
    return true;
}

fn bytes(ptr: ?*const anyopaque, len: c_int) []const u8 {
    const p: [*]const u8 = @ptrCast(ptr orelse return "");
    return p[0..@intCast(len)];
}

const canonicalInt = @import("sqlite_int.zig").canonicalInt;

test "canonical integers bind as integers, anything else as text" {
    try std.testing.expectEqual(@as(?i64, 0), canonicalInt("0"));
    try std.testing.expectEqual(@as(?i64, -42), canonicalInt("-42"));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), canonicalInt("9223372036854775807"));
    for ([_][]const u8{ "007", "-0", "+1", "1.5", "", "-", "9223372036854775808", "1e3", " 1" }) |s|
        try std.testing.expectEqual(@as(?i64, null), canonicalInt(s));
}

test "the linked SQLite has RETURNING (3.35+)" {
    try std.testing.expect(c.sqlite3_libversion_number() >= 3_035_000);
}

const db = @import("db.zig");
const testing = std.testing;
const Timestamp = @import("timestamp.zig").Timestamp;

const Person = struct { id: i64, name: []const u8, email: ?[]const u8, active: bool, joined: ?Timestamp };

test "sqlite::memory:: typed rows, ?n parameters, NULL, booleans, timestamps" {
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try testing.expectEqual(db.Dialect.sqlite, pool.dialect());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try pool.execScript("CREATE TABLE people (id integer PRIMARY KEY, name text NOT NULL, email text UNIQUE, active integer NOT NULL DEFAULT 1, joined text)");
    const t = try Timestamp.parse("2026-10-27T08:30:00.125Z");
    try testing.expectEqual(1, try pool.exec("INSERT INTO people (name, email, joined) VALUES (?1, ?2, ?3)", .{ "Ada", "ada@example.com", t }));
    try testing.expectEqual(1, try pool.exec("INSERT INTO people (name, email, active) VALUES (?1, ?2, ?3)", .{ "Bo", @as(?[]const u8, null), false }));
    const people = try pool.query(a, Person, "SELECT id, name, email, active, joined FROM people ORDER BY id", .{});
    try testing.expectEqual(2, people.len);
    try testing.expectEqualStrings("ada@example.com", people[0].email.?);
    try testing.expect(people[0].active and !people[1].active);
    try testing.expectEqual(t.us, people[0].joined.?.us);
    try testing.expectEqual(null, people[1].email);
    // Stored as kick/db stores it: sortable text.
    const Raw = struct { joined: []const u8 };
    try testing.expectEqualStrings("2026-10-27 08:30:00.125", (try pool.queryOne(a, Raw, "SELECT joined FROM people WHERE id = ?1", .{1})).?.joined);
    // One parameter used twice.
    const Count = struct { n: i64 };
    try testing.expectEqual(1, (try pool.queryOne(a, Count, "SELECT count(*) AS n FROM people WHERE name = ?1 OR email = ?1", .{"Bo"})).?.n);
    try testing.expectEqual(2, try pool.exec("UPDATE people SET active = ?1", .{true}));
}

test "sqlite: text is bytes: NUL, non-ASCII; a numeric-looking string stays a string" {
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try pool.execScript("CREATE TABLE t (s text)");
    const odd = "a\x00b é 🎉";
    _ = try pool.exec("INSERT INTO t VALUES (?1), (?2)", .{ odd, "007" });
    const Row = struct { s: []const u8 };
    const rows = try pool.query(arena.allocator(), Row, "SELECT s FROM t ORDER BY rowid", .{});
    try testing.expectEqualStrings(odd, rows[0].s);
    try testing.expectEqualStrings("007", rows[1].s);
    // LIMIT takes a parameter.
    try testing.expectEqual(1, (try pool.query(arena.allocator(), Row, "SELECT s FROM t LIMIT ?1 OFFSET ?2", .{ 1, 1 })).len);
}

test "sqlite: a unique violation is Conflict, bad SQL DbError; transactions commit and roll back" {
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try pool.execScript("CREATE TABLE u (email text PRIMARY KEY)");
    _ = try pool.exec("INSERT INTO u VALUES (?1)", .{"a"});
    try testing.expectError(error.Conflict, pool.exec("INSERT INTO u VALUES (?1)", .{"a"}));
    try testing.expectError(error.DbError, pool.exec("SELEC nonsense", .{}));
    {
        var tx = try pool.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO u VALUES (?1)", .{"b"});
        try tx.commit();
    }
    {
        var tx = try pool.begin();
        defer tx.deinit(); // rolled back
        _ = try tx.exec("INSERT INTO u VALUES (?1)", .{"c"});
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Row = struct { email: []const u8 };
    try testing.expectEqual(2, (try pool.query(arena.allocator(), Row, "SELECT email FROM u", .{})).len);
    try pool.ping();
}

test "sqlite: a file, written by many tasks at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    const url = try std.fmt.allocPrint(arena.allocator(), "sqlite:{s}/app.db", .{dir});
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    try pool.execScript("CREATE TABLE n (v integer)");
    const Writer = struct {
        fn run(p: *db.Pool, failed: *std.atomic.Value(u32)) void {
            for (0..200) |i| _ = p.exec("INSERT INTO n VALUES (?1)", .{i}) catch {
                _ = failed.fetchAdd(1, .acq_rel);
            };
        }
    };
    var failed: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    for (0..2) |_| try group.concurrent(testing.io, Writer.run, .{ &pool, &failed });
    try group.await(testing.io);
    try testing.expectEqual(0, failed.load(.acquire));
    const Count = struct { n: i64 };
    try testing.expectEqual(400, (try pool.queryOne(arena.allocator(), Count, "SELECT count(*) AS n FROM n", .{})).?.n);
}

test "sqlite: two statements in one exec are refused, not half run; DDL reports no rows" {
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:" });
    defer pool.deinit();
    try pool.execScript("CREATE TABLE t (v integer)");
    try testing.expectError(error.DbError, pool.exec("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)", .{}));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try pool.queryOne(arena.allocator(), struct { n: i64 }, "SELECT count(*) AS n FROM t", .{})).?.n);
    // A trailing semicolon or comment is fine.
    try testing.expectEqual(1, try pool.exec("INSERT INTO t VALUES (1); -- done", .{}));
    try testing.expectEqual(0, try pool.exec("CREATE TABLE u (v integer)", .{}));
}

test "sqlite: the pool used inside its own transaction times out instead of hanging" {
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = "sqlite::memory:", .acquire_timeout_ms = 50 });
    defer pool.deinit();
    var tx = try pool.begin();
    defer tx.deinit();
    try testing.expectError(error.ServiceUnavailable, pool.exec("SELECT 1", .{}));
}

test "sqlite: a transaction that reads then writes isn't undone by a writer from another pool" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    const url = try std.fmt.allocPrint(arena.allocator(), "sqlite:{s}/app.db", .{dir});
    var app: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer app.deinit();
    var cli: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer cli.deinit();
    try app.execScript("CREATE TABLE n (v integer)");
    const Other = struct {
        fn run(p: *db.Pool, failed: *std.atomic.Value(u32)) void {
            testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
            _ = p.exec("INSERT INTO n VALUES (?1)", .{2}) catch {
                _ = failed.fetchAdd(1, .acq_rel);
            };
        }
    };
    var failed: std.atomic.Value(u32) = .init(0);
    var tx = try app.begin();
    defer tx.deinit();
    var other = try testing.io.concurrent(Other.run, .{ &cli, &failed });
    _ = try tx.query(arena.allocator(), struct { v: i64 }, "SELECT v FROM n", .{});
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    _ = try tx.exec("INSERT INTO n VALUES (?1)", .{1});
    try tx.commit();
    other.await(testing.io);
    try testing.expectEqual(0, failed.load(.acquire));
}
