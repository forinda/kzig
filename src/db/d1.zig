//! Cloudflare D1 over its REST API (`POST …/d1/database/<id>/query`):
//! `d1://<account id>/<database id>?token=…`. D1 has no interactive
//! transactions; a batch is one, and migrations go as batches.

const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg.zig");

const Allocator = std.mem.Allocator;
const Error = pg.Error;

/// D1 binds at most 100 parameters per statement.
pub const max_params = 100;

pub const Stmt = struct { sql: []const u8, params: []const ?[]const u8 = &.{} };

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    http: std.http.Client,
    arena: std.heap.ArenaAllocator,
    endpoint: []const u8,
    authorization: []const u8,

    /// `d1://<account id>/<database id>?token=…`; `&endpoint=` replaces
    /// `https://api.cloudflare.com/client/v4` (tests, a proxy).
    pub fn init(io: std.Io, gpa: Allocator, url: []const u8) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .http = .{ .allocator = gpa, .io = io }, .arena = .init(gpa), .endpoint = "", .authorization = "" };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const rest = url["d1://".len..];
        const q = std.mem.findScalar(u8, rest, '?') orelse return error.InvalidDatabaseUrl;
        const ids = rest[0..q];
        const slash = std.mem.findScalar(u8, ids, '/') orelse return error.InvalidDatabaseUrl;
        const account = ids[0..slash];
        const database = ids[slash + 1 ..];
        if (account.len == 0 or database.len == 0 or std.mem.findScalar(u8, database, '/') != null) return error.InvalidDatabaseUrl;
        var base: []const u8 = "https://api.cloudflare.com/client/v4";
        var token: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, rest[q + 1 ..], '&');
        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=') orelse return error.InvalidDatabaseUrl;
            if (std.mem.eql(u8, kv[0..eq], "token")) token = kv[eq + 1 ..] else if (std.mem.eql(u8, kv[0..eq], "endpoint")) base = std.mem.trimEnd(u8, kv[eq + 1 ..], "/") else return error.InvalidDatabaseUrl;
        }
        c.endpoint = try std.fmt.allocPrint(a, "{s}/accounts/{s}/d1/database/{s}/query", .{ base, account, database });
        c.authorization = try std.mem.concat(a, u8, &.{ "Bearer ", token orelse return error.InvalidDatabaseUrl });
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    pub fn run(c: *Client, sql: []const u8, params: []const ?[]const u8, ctx: anytype, comptime row: anytype) Error!u64 {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.Io.Writer.Allocating = .init(a);
        writeStmt(&body.writer, .{ .sql = sql, .params = params }) catch return error.OutOfMemory;
        try checkParams(params);
        const result = try c.post(a, body.written());
        const first = if (result.len > 0) result[0] else return 0;
        const rows = (field(first, "results") orelse return error.DbDecode);
        if (rows != .array) return error.DbDecode;
        if (rows.array.items.len == 0) {
            const changes = field(field(first, "meta") orelse .null, "changes") orelse return 0;
            return switch (changes) {
                .number_string => |t| std.fmt.parseInt(u64, t, 10) catch 0,
                .integer => |i| @intCast(i),
                else => 0,
            };
        }
        // Rows are objects: the first one's keys name the columns.
        const first_row = rows.array.items[0];
        if (first_row != .object) return error.DbDecode;
        const names = first_row.object.keys();
        const values = try a.alloc(?[]const u8, names.len);
        for (rows.array.items) |r| {
            if (r != .object) return error.DbDecode;
            for (names, values) |n, *out| out.* = try cell(a, r.object.get(n) orelse .null);
            try row(ctx, names, values);
        }
        return rows.array.items.len;
    }

    /// Several statements, no parameters (D1 runs them as a batch).
    pub fn script(c: *Client, sql: []const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var body: std.Io.Writer.Allocating = .init(arena.allocator());
        writeStmt(&body.writer, .{ .sql = sql }) catch return error.OutOfMemory;
        _ = try c.post(arena.allocator(), body.written());
    }

    /// One transaction: every statement applies, or none.
    pub fn batch(c: *Client, stmts: []const Stmt) Error!void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var body: std.Io.Writer.Allocating = .init(arena.allocator());
        const w = &body.writer;
        (blk: {
            w.writeAll("{\"batch\":[") catch |e| break :blk e;
            for (stmts, 0..) |s, i| {
                if (i > 0) w.writeByte(',') catch |e| break :blk e;
                writeStmt(w, s) catch |e| break :blk e;
            }
            w.writeAll("]}") catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        for (stmts) |s| try checkParams(s.params);
        _ = try c.post(arena.allocator(), body.written());
    }

    /// The request; its `result` array, or the error D1 reports.
    fn post(c: *Client, a: Allocator, body: []const u8) Error![]const std.json.Value {
        var out: std.Io.Writer.Allocating = .init(a);
        const res = c.http.fetch(.{
            .location = .{ .url = c.endpoint },
            .method = .POST,
            .payload = body,
            // `privileged_headers` aren't sent by std 0.17's client; the
            // token goes in `authorization`, and no redirect carries it on.
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = c.authorization } },
            .redirect_behavior = .unhandled,
            .response_writer = &out.writer,
        }) catch |err| {
            if (!builtin.is_test) std.log.err("db: d1: {t}", .{err});
            return error.ServiceUnavailable;
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{ .parse_numbers = false }) catch {
            if (!builtin.is_test) std.log.err("db: d1: HTTP {d}: {s}", .{ @backingInt(res.status), out.written() });
            return if (res.status == .ok) error.DbDecode else error.ServiceUnavailable;
        };
        const ok = field(v, "success");
        if (ok == null or ok.? != .bool or !ok.?.bool) {
            const errors = field(v, "errors") orelse .null;
            const message = if (errors == .array and errors.array.items.len > 0) (if (field(errors.array.items[0], "message")) |m| (if (m == .string) m.string else "") else "") else "";
            if (!builtin.is_test) std.log.err("db: d1: HTTP {d}: {s}", .{ @backingInt(res.status), message });
            if (std.mem.find(u8, message, "UNIQUE constraint failed") != null) return error.Conflict;
            // Not a statement's error: the token, the database, the service.
            if (res.status == .unauthorized or res.status == .forbidden or @backingInt(res.status) >= 500) return error.ServiceUnavailable;
            return error.DbError;
        }
        const result = field(v, "result") orelse return &.{};
        return if (result == .array) result.array.items else error.DbDecode;
    }
};

fn checkParams(params: []const ?[]const u8) Error!void {
    if (params.len <= max_params) return;
    if (!builtin.is_test) std.log.err("db: d1: {d} parameters in one statement; D1 binds at most {d}", .{ params.len, max_params });
    return error.TooManyParameters;
}

fn writeStmt(w: *std.Io.Writer, s: Stmt) !void {
    try w.writeAll("{\"sql\":");
    try std.json.Stringify.value(s.sql, .{}, w);
    if (s.params.len > 0) {
        try w.writeAll(",\"params\":");
        try std.json.Stringify.value(s.params, .{}, w);
    }
    try w.writeByte('}');
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

/// A D1 value as the text cell rows decode from; a blob comes as an array
/// of bytes.
fn cell(a: Allocator, v: std.json.Value) Error!?[]const u8 {
    return switch (v) {
        .null => null,
        .string, .number_string => |t| t,
        .bool => |b| if (b) "1" else "0",
        .array => |arr| blk: {
            const out = try a.alloc(u8, arr.items.len);
            for (arr.items, out) |x, *o| o.* = switch (x) {
                .number_string => |t| std.fmt.parseInt(u8, t, 10) catch return error.DbDecode,
                .integer => |i| std.math.cast(u8, i) orelse return error.DbDecode,
                else => return error.DbDecode,
            };
            break :blk out;
        },
        else => error.DbDecode,
    };
}

/// kick/db's `splitSqlStatements` for SQLite: at top-level `;`, not inside
/// quotes or comments. A trigger body (`BEGIN … ; … END`) doesn't split
/// right, as in kick/db.
pub fn split(a: Allocator, sql: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < sql.len) : (i += 1) {
        const ch = sql[i];
        if (quote != 0) {
            if (ch == quote) {
                if (quote != '`' and i + 1 < sql.len and sql[i + 1] == quote) i += 1 else quote = 0;
            }
            continue;
        }
        switch (ch) {
            '\'', '"', '`' => quote = ch,
            '-' => if (i + 1 < sql.len and sql[i + 1] == '-') {
                i = std.mem.findScalarPos(u8, sql, i, '\n') orelse sql.len;
            },
            '/' => if (i + 1 < sql.len and sql[i + 1] == '*') {
                i = if (std.mem.findPos(u8, sql, i + 2, "*/")) |e| e + 1 else sql.len;
            },
            ';' => {
                const s = std.mem.trim(u8, sql[start..i], " \t\r\n");
                if (s.len > 0) try out.append(a, s);
                start = i + 1;
            },
            else => {},
        }
    }
    const tail = std.mem.trim(u8, sql[@min(start, sql.len)..], " \t\r\n");
    if (tail.len > 0) try out.append(a, tail);
    return out.items;
}

test "split: at top-level semicolons only, as kick/db" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try split(arena.allocator(), "-- a; comment\nCREATE TABLE \"a;b\" (x text DEFAULT 'it''s; here');\n/* c; */ INSERT INTO t VALUES (1) ;; SELECT 2");
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqualStrings("-- a; comment\nCREATE TABLE \"a;b\" (x text DEFAULT 'it''s; here')", got[0]);
    try std.testing.expectEqualStrings("/* c; */ INSERT INTO t VALUES (1)", got[1]);
    try std.testing.expectEqualStrings("SELECT 2", got[2]);
}

const db = @import("db.zig");
const testing = std.testing;

/// A stand-in for D1's endpoint, run by a real local SQLite: requests and
/// answers in the shapes Cloudflare documents (`{sql, params}` or `{batch}`;
/// `{result: [{results, success, meta}], success, errors}`).
const FakeD1 = if (@import("kzig_options").sqlite) struct {
    const sqlite = @import("sqlite.zig");
    listener: std.Io.net.Server,
    conn: *sqlite.Conn,
    fut: std.Io.Future(void) = undefined,
    requests: std.atomic.Value(u32) = .init(0),
    last_auth: [64]u8 = undefined,
    last_auth_len: usize = 0,

    fn start(f: *FakeD1) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        f.* = .{ .listener = try address.listen(testing.io, .{ .reuse_address = true }), .conn = try sqlite.Conn.open(testing.allocator, ":memory:") };
        f.fut = try testing.io.concurrent(serve, .{f});
    }

    fn stop(f: *FakeD1) void {
        f.fut.cancel(testing.io);
        f.listener.deinit(testing.io);
        f.conn.close();
    }

    fn url(f: *FakeD1, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "d1://acct/dbid?token=secret&endpoint=http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()});
    }

    fn serve(f: *FakeD1) void {
        while (true) {
            const stream = f.listener.accept(testing.io) catch return;
            defer stream.close(testing.io);
            var rbuf: [16384]u8 = undefined;
            var wbuf: [16384]u8 = undefined;
            var sr = stream.reader(testing.io, &rbuf);
            var sw = stream.writer(testing.io, &wbuf);
            var server = std.http.Server.init(&sr.interface, &sw.interface);
            while (true) {
                var req = server.receiveHead() catch break;
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                f.answer(&req, arena.allocator()) catch break;
            }
        }
    }

    fn answer(f: *FakeD1, req: *std.http.Server.Request, a: std.mem.Allocator) !void {
        _ = f.requests.fetchAdd(1, .acq_rel);
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            f.last_auth_len = @min(h.value.len, f.last_auth.len);
            @memcpy(f.last_auth[0..f.last_auth_len], h.value[0..f.last_auth_len]);
        };
        const path_ok = std.mem.eql(u8, req.head.target, "/accounts/acct/d1/database/dbid/query");
        var body_buf: [4096]u8 = undefined;
        const body = try req.server.reader.bodyReader(&body_buf, req.head.transfer_encoding, req.head.content_length).allocRemaining(a, .limited(1 << 20));
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        var out: std.Io.Writer.Allocating = .init(a);
        var status: std.http.Status = .ok;
        if (!path_ok) {
            status = .not_found;
            try out.writer.writeAll("{\"result\":[],\"success\":false,\"errors\":[{\"code\":7404,\"message\":\"no such database\"}],\"messages\":[]}");
        } else if (v.object.get("batch")) |batch| {
            try f.conn.script("BEGIN");
            var results: std.Io.Writer.Allocating = .init(a);
            for (batch.array.items, 0..) |stmt, i| {
                if (i > 0) try results.writer.writeByte(',');
                f.one(a, stmt, &results.writer) catch {
                    const msg = try a.dupe(u8, f.conn.lastError());
                    f.conn.script("ROLLBACK") catch {};
                    status = .bad_request;
                    try fail(&out.writer, msg);
                    break;
                };
            } else {
                try f.conn.script("COMMIT");
                try out.writer.print("{{\"result\":[{s}],\"success\":true,\"errors\":[],\"messages\":[]}}", .{results.written()});
            }
        } else {
            var results: std.Io.Writer.Allocating = .init(a);
            if (f.one(a, v, &results.writer)) {
                try out.writer.print("{{\"result\":[{s}],\"success\":true,\"errors\":[],\"messages\":[]}}", .{results.written()});
            } else |_| {
                status = .bad_request;
                try fail(&out.writer, f.conn.lastError());
            }
        }
        try req.respond(out.written(), .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn fail(w: *std.Io.Writer, msg: []const u8) !void {
        try w.writeAll("{\"result\":[],\"success\":false,\"errors\":[{\"code\":7500,\"message\":\"D1_ERROR: ");
        try std.json.Stringify.encodeJsonStringChars(msg, .{}, w);
        try w.writeByte('"');
        try w.writeAll("}],\"messages\":[]}");
    }

    /// One `{sql, params}`: rows as objects, as D1 returns them.
    fn one(f: *FakeD1, a: std.mem.Allocator, stmt: std.json.Value, w: *std.Io.Writer) !void {
        const sql = stmt.object.get("sql").?.string;
        var params: std.ArrayList(?[]const u8) = .empty;
        if (stmt.object.get("params")) |ps| for (ps.array.items) |p| try params.append(a, switch (p) {
            .null => null,
            .string => |t| t,
            .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
            else => return error.BadParam,
        });
        const Rows = struct {
            w: *std.Io.Writer,
            first: bool = true,
            fn add(r: *@This(), names: []const []const u8, values: []const ?[]const u8) error{OutOfMemory}!void {
                r.write(names, values) catch return error.OutOfMemory;
            }
            fn write(r: *@This(), names: []const []const u8, values: []const ?[]const u8) !void {
                try r.w.writeAll(if (r.first) "{" else ",{");
                r.first = false;
                for (names, values, 0..) |n, val, i| {
                    if (i > 0) try r.w.writeByte(',');
                    try std.json.Stringify.value(n, .{}, r.w);
                    try r.w.writeByte(':');
                    if (val) |x| {
                        if (@import("sqlite_int.zig").canonicalInt(x) != null) try r.w.writeAll(x) else try std.json.Stringify.value(x, .{}, r.w);
                    } else try r.w.writeAll("null");
                }
                try r.w.writeByte('}');
            }
        };
        try w.writeAll("{\"results\":[");
        var rows: Rows = .{ .w = w };
        // Several statements without parameters run as a script (D1 batches them).
        const changes = if (params.items.len == 0 and std.mem.countScalar(u8, std.mem.trimEnd(u8, sql, " \n;"), ';') > 0) blk: {
            try f.conn.script(sql);
            break :blk 0;
        } else try f.conn.run(sql, params.items, &rows, Rows.add);
        try w.print("],\"success\":true,\"meta\":{{\"changes\":{d},\"last_row_id\":0}}}}", .{if (rows.first) changes else 0});
    }
} else void;

fn fakePool(fake: anytype, a: std.mem.Allocator) !db.Pool {
    return .init(testing.io, testing.allocator, .{ .url = try fake.url(a) });
}

test "d1: rows, parameters, NULL, errors, the token sent" {
    if (FakeD1 == void) return error.SkipZigTest;
    var fake: FakeD1 = undefined;
    try fake.start();
    defer fake.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pool = try fakePool(&fake, a);
    defer pool.deinit();
    try testing.expectEqual(db.Dialect.sqlite, pool.dialect());
    try pool.execScript("CREATE TABLE t (id integer PRIMARY KEY, name text NOT NULL UNIQUE, note text); CREATE TABLE _cf_KV (k text)");
    try testing.expectEqual(1, try pool.exec("INSERT INTO t (name, note) VALUES (?1, ?2)", .{ "Ada é", @as(?[]const u8, null) }));
    const Row = struct { id: i64, name: []const u8, note: ?[]const u8 };
    const rows = try pool.query(a, Row, "SELECT id, name, note FROM t WHERE id = ?1 LIMIT ?2", .{ 1, 5 });
    try testing.expectEqual(1, rows.len);
    try testing.expectEqualStrings("Ada é", rows[0].name);
    try testing.expectEqual(null, rows[0].note);
    try testing.expectError(error.Conflict, pool.exec("INSERT INTO t (name) VALUES (?1)", .{"Ada é"}));
    try testing.expectError(error.DbError, pool.exec("SELEC nonsense", .{}));
    try testing.expectEqualStrings("Bearer secret", fake.last_auth[0..fake.last_auth_len]);
}

test "d1: no transactions; more than 100 parameters is refused before sending" {
    if (FakeD1 == void) return error.SkipZigTest;
    var fake: FakeD1 = undefined;
    try fake.start();
    defer fake.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var pool = try fakePool(&fake, arena.allocator());
    defer pool.deinit();
    try testing.expectError(error.TransactionsUnsupported, pool.begin());
    const params: [101]?[]const u8 = @splat("1");
    const before = fake.requests.load(.acquire);
    try testing.expectError(error.TooManyParameters, pool.execParams("SELECT 1", &params));
    try testing.expectEqual(before, fake.requests.load(.acquire));
}

test "d1: migrations as one batch each; a failing one leaves nothing; a rebuild of a referenced table is refused" {
    if (FakeD1 == void) return error.SkipZigTest;
    var fake: FakeD1 = undefined;
    try fake.start();
    defer fake.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pool = try fakePool(&fake, a);
    defer pool.deinit();
    const migrate = @import("migrate.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const add = struct {
        fn f(d: std.Io.Dir, id: []const u8, up: []const u8) !void {
            try d.createDirPath(testing.io, id);
            var buf: [256]u8 = undefined;
            try d.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/up.sql", .{id}), .data = up });
            try d.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/down.sql", .{id}), .data = "" });
        }
    }.f;
    try add(tmp.dir, "20260101_000000_a",
        \\-- Generated by kzig — review state lives in meta.json
        \\CREATE TABLE "users" ("id" INTEGER PRIMARY KEY, "name" TEXT);
        \\CREATE TABLE "posts" ("id" INTEGER PRIMARY KEY, "authorId" INTEGER NOT NULL, FOREIGN KEY ("authorId") REFERENCES "users" ("id") ON DELETE CASCADE);
        \\INSERT INTO "users" VALUES (1, 'semi;colon');
        \\INSERT INTO "posts" VALUES (1, 1);
    );
    const o: migrate.Options = .{ .table = "kzig_test_migrations" };
    try testing.expectEqual(1, (try migrate.latest(&pool, a, try migrate.load(testing.io, a, dir), o)).applied);
    try testing.expectEqualStrings("semi;colon", (try pool.queryOne(a, struct { name: []const u8 }, "SELECT name FROM users", .{})).?.name);
    // Its second statement fails: the first is rolled back with it.
    try add(tmp.dir, "20260102_000000_b", "CREATE TABLE \"x\" (\"id\" INTEGER);\nSELECT nonsense FROM nowhere;");
    try testing.expectError(error.DbError, migrate.latest(&pool, a, try migrate.load(testing.io, a, dir), o));
    try testing.expectError(error.DbError, pool.exec("SELECT * FROM x", .{}));
    try tmp.dir.deleteTree(testing.io, "20260102_000000_b");
    // Rebuilding users would cascade into posts (D1 keeps foreign keys on).
    try add(tmp.dir, "20260103_000000_c",
        \\CREATE TABLE "_kick_new_users" ("id" INTEGER PRIMARY KEY, "name" TEXT NOT NULL);
        \\INSERT INTO "_kick_new_users" ("id", "name") SELECT "id", "name" FROM "users";
        \\DROP TABLE "users";
        \\ALTER TABLE "_kick_new_users" RENAME TO "users";
    );
    try testing.expectError(error.RebuildOfReferencedTable, migrate.latest(&pool, a, try migrate.load(testing.io, a, dir), o));
    try testing.expectEqual(1, (try pool.queryOne(a, struct { n: i64 }, "SELECT count(*) AS n FROM posts", .{})).?.n);
}
