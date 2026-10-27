//! Turso / libsql over HTTP: Hrana's `/v2/pipeline` (no C, no WebSocket).
//! `libsql://host?authToken=…` (https), or `http://host:8080` for a local
//! `sqld`. A transaction is one Hrana stream, kept by its baton.
const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg.zig");

const Allocator = std.mem.Allocator;
const Error = pg.Error;

/// One per pool: the endpoint and an HTTP client its sessions share.
pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    http: std.http.Client,
    arena: std.heap.ArenaAllocator,
    /// `<base>/v2/pipeline`.
    endpoint: []const u8,
    /// `Bearer <authToken>`, when the URL has one.
    authorization: ?[]const u8,

    /// `libsql://host[:port][?authToken=…]` (https), or `http(s)://…`.
    pub fn init(io: std.Io, gpa: Allocator, url: []const u8) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .http = .{ .allocator = gpa, .io = io }, .arena = .init(gpa), .endpoint = "", .authorization = null };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const rest = if (std.mem.startsWith(u8, url, "libsql://")) try std.mem.concat(a, u8, &.{ "https://", url["libsql://".len..] }) else url;
        const q = std.mem.findScalar(u8, rest, '?');
        const base = std.mem.trimEnd(u8, rest[0 .. q orelse rest.len], "/");
        _ = std.Uri.parse(base) catch return error.InvalidDatabaseUrl;
        c.endpoint = try std.mem.concat(a, u8, &.{ base, "/v2/pipeline" });
        if (q) |i| {
            var it = std.mem.splitScalar(u8, rest[i + 1 ..], '&');
            while (it.next()) |kv| {
                const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
                if (!std.mem.eql(u8, kv[0..eq], "authToken")) return error.InvalidDatabaseUrl;
                c.authorization = try std.mem.concat(a, u8, &.{ "Bearer ", kv[eq + 1 ..] });
            }
        }
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        c.arena.deinit();
        c.gpa.destroy(c);
    }
};

/// A Hrana stream. Outside a transaction each request opens and closes one;
/// in a transaction (`keep`) the baton carries it from request to request.
pub const Session = struct {
    client: *Client,
    baton: ?[]u8 = null,
    /// The stream's later requests go here when the server names it
    /// (Hrana's `base_url`: the replica that holds the stream).
    endpoint: ?[]u8 = null,
    keep: bool = false,

    pub fn open(client: *Client) !*Session {
        const s = try client.gpa.create(Session);
        s.* = .{ .client = client };
        return s;
    }

    /// Closes the stream if one is open (a transaction left open is rolled
    /// back with it).
    pub fn close(s: *Session) void {
        if (s.baton != null) {
            s.keep = false;
            var arena: std.heap.ArenaAllocator = .init(s.client.gpa);
            defer arena.deinit();
            _ = s.pipeline(arena.allocator(), null) catch {};
        }
        s.setBaton(null);
        if (s.endpoint) |e| s.client.gpa.free(e);
        s.client.gpa.destroy(s);
    }

    /// Tests: the stream as if it had expired on the server.
    pub fn forgetBaton(s: *Session) void {
        s.setBaton("expired");
    }

    fn setBaton(s: *Session, b: ?[]const u8) void {
        if (s.baton) |old| s.client.gpa.free(old);
        s.baton = if (b) |x| s.client.gpa.dupe(u8, x) catch null else null;
    }

    pub fn run(s: *Session, sql: []const u8, params: []const ?[]const u8, ctx: anytype, comptime row: anytype) Error!u64 {
        var arena: std.heap.ArenaAllocator = .init(s.client.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var req: std.Io.Writer.Allocating = .init(a);
        const w = &req.writer;
        w.writeAll("{\"type\":\"execute\",\"stmt\":{\"sql\":") catch return error.OutOfMemory;
        std.json.Stringify.value(sql, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"args\":[") catch return error.OutOfMemory;
        for (params, 0..) |p, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            writeValue(w, p) catch return error.OutOfMemory;
        }
        w.writeAll("]}}") catch return error.OutOfMemory;
        const result = try s.pipeline(a, req.written());
        const cols = (field(result, "cols") orelse return error.DbDecode).array.items;
        const names = try a.alloc([]const u8, cols.len);
        for (cols, names) |col, *n| n.* = if (field(col, "name")) |v| (if (v == .string) v.string else "") else "";
        const values = try a.alloc(?[]const u8, cols.len);
        const rows = (field(result, "rows") orelse return error.DbDecode).array.items;
        for (rows) |r| {
            if (r != .array or r.array.items.len != cols.len) return error.DbDecode;
            for (r.array.items, values) |v, *out| out.* = try cell(a, v);
            try row(ctx, names, values);
        }
        if (cols.len > 0) return rows.len;
        const n = field(result, "affected_row_count") orelse return 0;
        return switch (n) {
            .integer => |i| @intCast(i),
            .number_string => |t| std.fmt.parseInt(u64, t, 10) catch 0,
            else => 0,
        };
    }

    /// Several statements, no parameters (Hrana's `sequence`).
    pub fn script(s: *Session, sql: []const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(s.client.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var req: std.Io.Writer.Allocating = .init(a);
        req.writer.writeAll("{\"type\":\"sequence\",\"sql\":") catch return error.OutOfMemory;
        std.json.Stringify.value(sql, .{}, &req.writer) catch return error.OutOfMemory;
        req.writer.writeByte('}') catch return error.OutOfMemory;
        _ = try s.pipeline(a, req.written());
    }

    /// One request (and a close, outside a transaction); its result.
    /// ponytail: no request timeout (std's fetch has none); add a watchdog
    /// like storage/s3.zig's if a stalled Turso connection bites.
    fn pipeline(s: *Session, a: Allocator, request: ?[]const u8) Error!std.json.Value {
        var body: std.Io.Writer.Allocating = .init(a);
        const w = &body.writer;
        (blk: {
            w.writeAll("{\"baton\":") catch |e| break :blk e;
            std.json.Stringify.value(s.baton, .{}, w) catch |e| break :blk e;
            w.writeAll(",\"requests\":[") catch |e| break :blk e;
            if (request) |r| w.writeAll(r) catch |e| break :blk e;
            if (!s.keep) w.writeAll(if (request != null) ",{\"type\":\"close\"}" else "{\"type\":\"close\"}") catch |e| break :blk e;
            w.writeAll("]}") catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        var out: std.Io.Writer.Allocating = .init(a);
        const res = s.client.http.fetch(.{
            .location = .{ .url = s.endpoint orelse s.client.endpoint },
            .method = .POST,
            .payload = body.written(),
            // `privileged_headers` aren't sent by std 0.17's client; the
            // token goes in `authorization`, and no redirect carries it on.
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (s.client.authorization) |v| .{ .override = v } else .default,
            },
            .redirect_behavior = .unhandled,
            .response_writer = &out.writer,
        }) catch |err| {
            if (!builtin.is_test) std.log.err("db: libsql {s}: {t}", .{ s.client.endpoint, err });
            s.setBaton(null);
            return error.ServiceUnavailable;
        };
        // An HTTP error ends the stream (Hrana): its transaction is gone.
        if (res.status != .ok) {
            if (!builtin.is_test) std.log.err("db: libsql: HTTP {d}: {s}", .{ @backingInt(res.status), out.written() });
            s.setBaton(null);
            return error.ServiceUnavailable;
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{ .parse_numbers = false }) catch return error.DbDecode;
        const baton = field(v, "baton");
        s.setBaton(if (baton != null and baton.? == .string) baton.?.string else null);
        if (field(v, "base_url")) |b| if (b == .string) {
            if (s.endpoint) |e| s.client.gpa.free(e);
            s.endpoint = std.mem.concat(s.client.gpa, u8, &.{ std.mem.trimEnd(u8, b.string, "/"), "/v2/pipeline" }) catch null;
        };
        if (request == null) return .null;
        const results = (field(v, "results") orelse return error.DbDecode);
        if (results != .array or results.array.items.len == 0) return error.DbDecode;
        const first = results.array.items[0];
        const kind = (field(first, "type") orelse return error.DbDecode).string;
        if (std.mem.eql(u8, kind, "error")) return fail(field(first, "error") orelse .null);
        const response = field(first, "response") orelse return error.DbDecode;
        return field(response, "result") orelse .null;
    }
};

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

/// SQLite's codes come through as text; a unique or primary key is Conflict.
fn fail(e: std.json.Value) Error {
    const message = if (field(e, "message")) |m| (if (m == .string) m.string else "") else "";
    const code = if (field(e, "code")) |c| (if (c == .string) c.string else "") else "";
    if (!builtin.is_test) std.log.err("db: libsql: {s} ({s})", .{ message, code });
    if (std.mem.find(u8, message, "UNIQUE constraint failed") != null or std.mem.eql(u8, code, "SQLITE_CONSTRAINT_UNIQUE") or std.mem.eql(u8, code, "SQLITE_CONSTRAINT_PRIMARYKEY"))
        return error.Conflict;
    return error.DbError;
}

/// A text parameter as a Hrana value: a canonical integer as `integer`,
/// as the local driver binds it.
fn writeValue(w: *std.Io.Writer, p: ?[]const u8) !void {
    const v = p orelse return w.writeAll("{\"type\":\"null\"}");
    if (@import("sqlite_int.zig").canonicalInt(v) != null) return w.print("{{\"type\":\"integer\",\"value\":\"{s}\"}}", .{v});
    try w.writeAll("{\"type\":\"text\",\"value\":");
    try std.json.Stringify.value(v, .{}, w);
    try w.writeByte('}');
}

/// A Hrana value as the text cell rows decode from.
fn cell(a: Allocator, v: std.json.Value) Error!?[]const u8 {
    const kind = (field(v, "type") orelse return error.DbDecode);
    if (kind != .string) return error.DbDecode;
    if (std.mem.eql(u8, kind.string, "null")) return null;
    if (std.mem.eql(u8, kind.string, "blob")) {
        const b64 = (field(v, "base64") orelse return error.DbDecode).string;
        const D = std.base64.standard_no_pad.Decoder;
        const trimmed = std.mem.trimEnd(u8, b64, "=");
        const out = try a.alloc(u8, D.calcSizeForSlice(trimmed) catch return error.DbDecode);
        D.decode(out, trimmed) catch return error.DbDecode;
        return out;
    }
    return switch (field(v, "value") orelse return error.DbDecode) {
        .string, .number_string => |t| t,
        else => error.DbDecode,
    };
}

const db = @import("db.zig");
const testing = std.testing;

/// `LIBSQL_TEST_URL` (a `sqld`, e.g. `http://127.0.0.1:8080`); skipped without one.
fn testUrl(buf: *std.process.Environ.Map) ![]const u8 {
    buf.* = try testing.environ.createMap(testing.allocator);
    return buf.get("LIBSQL_TEST_URL") orelse error.SkipZigTest;
}

fn testPool(env: *std.process.Environ.Map) !db.Pool {
    const url = testUrl(env) catch |err| {
        if (err == error.SkipZigTest) env.deinit();
        return err;
    };
    return .init(testing.io, testing.allocator, .{ .url = url });
}

test "libsql: rows, ?n parameters, NULL, integers past 2^53, text, errors" {
    var env: std.process.Environ.Map = undefined;
    var pool = try testPool(&env);
    defer env.deinit();
    defer pool.deinit();
    try testing.expectEqual(db.Dialect.sqlite, pool.dialect());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try pool.execScript("DROP TABLE IF EXISTS kzig_ls; CREATE TABLE kzig_ls (id integer PRIMARY KEY, name text NOT NULL UNIQUE, big integer, score real, raw blob)");
    defer pool.execScript("DROP TABLE IF EXISTS kzig_ls") catch {};
    try testing.expectEqual(1, try pool.exec("INSERT INTO kzig_ls (name, big, score, raw) VALUES (?1, ?2, ?3, x'00ff')", .{ "Ada é", @as(i64, 9007199254740993), 1.5 }));
    try testing.expectEqual(1, try pool.exec("INSERT INTO kzig_ls (name) VALUES (?1)", .{"Bo"}));
    const Row = struct { id: i64, name: []const u8, big: ?i64, score: ?f64, raw: ?[]const u8 };
    const rows = try pool.query(a, Row, "SELECT id, name, big, score, raw FROM kzig_ls ORDER BY id LIMIT ?1", .{10});
    try testing.expectEqual(2, rows.len);
    try testing.expectEqualStrings("Ada é", rows[0].name);
    try testing.expectEqual(9007199254740993, rows[0].big.?);
    try testing.expectEqual(1.5, rows[0].score.?);
    try testing.expectEqualSlices(u8, &.{ 0, 0xff }, rows[0].raw.?);
    try testing.expectEqual(null, rows[1].big);
    try testing.expectError(error.Conflict, pool.exec("INSERT INTO kzig_ls (name) VALUES (?1)", .{"Bo"}));
    try testing.expectError(error.DbError, pool.exec("SELEC nonsense", .{}));
    try pool.ping();
}

test "libsql: a transaction is one stream: commit keeps, rollback and deinit discard" {
    var env: std.process.Environ.Map = undefined;
    var pool = try testPool(&env);
    defer env.deinit();
    defer pool.deinit();
    try pool.execScript("DROP TABLE IF EXISTS kzig_lt; CREATE TABLE kzig_lt (v integer)");
    defer pool.execScript("DROP TABLE IF EXISTS kzig_lt") catch {};
    {
        var tx = try pool.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_lt VALUES (?1)", .{1});
        // Inside the stream the write is visible.
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqual(1, (try tx.query(arena.allocator(), struct { v: i64 }, "SELECT v FROM kzig_lt", .{})).len);
        try tx.commit();
    }
    {
        var tx = try pool.begin();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO kzig_lt VALUES (?1)", .{2});
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(1, (try pool.query(arena.allocator(), struct { v: i64 }, "SELECT v FROM kzig_lt", .{})).len);
}

test "libsql: a stream the server dropped fails the transaction; nothing half-commits" {
    var env: std.process.Environ.Map = undefined;
    var pool = try testPool(&env);
    defer env.deinit();
    defer pool.deinit();
    try pool.execScript("DROP TABLE IF EXISTS kzig_lb; CREATE TABLE kzig_lb (v integer)");
    defer pool.execScript("DROP TABLE IF EXISTS kzig_lb") catch {};
    var tx = try pool.begin();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO kzig_lb VALUES (?1)", .{1});
    tx.conn.?.libsql.forgetBaton(); // as if it expired
    try testing.expectError(error.ServiceUnavailable, tx.commit());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try pool.query(arena.allocator(), struct { v: i64 }, "SELECT v FROM kzig_lb", .{})).len);
}

/// Records each request's target, baton and authorization; answers as sqld.
const FakeHrana = struct {
    listener: std.Io.net.Server,
    fut: std.Io.Future(void) = undefined,
    log: [8][160]u8 = undefined,
    n: usize = 0,

    fn start(f: *FakeHrana) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        f.* = .{ .listener = try address.listen(testing.io, .{ .reuse_address = true }) };
        f.fut = try testing.io.concurrent(serve, .{f});
    }

    fn stop(f: *FakeHrana) void {
        f.fut.cancel(testing.io);
        f.listener.deinit(testing.io);
    }

    fn port(f: *FakeHrana) u16 {
        return f.listener.socket.address.getPort();
    }

    fn serve(f: *FakeHrana) void {
        while (true) {
            const stream = f.listener.accept(testing.io) catch return;
            defer stream.close(testing.io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = stream.reader(testing.io, &rbuf);
            var sw = stream.writer(testing.io, &wbuf);
            var server = std.http.Server.init(&sr.interface, &sw.interface);
            while (true) {
                var req = server.receiveHead() catch break;
                f.answer(&req) catch break;
            }
        }
    }

    fn answer(f: *FakeHrana, req: *std.http.Server.Request) !void {
        var auth: []const u8 = "-";
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            auth = h.value;
        };
        var line: [160]u8 = undefined;
        const head = try std.fmt.bufPrint(&line, "{s} {s}", .{ req.head.target, auth });
        var body_buf: [4096]u8 = undefined;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const body = try req.server.reader.bodyReader(&body_buf, req.head.transfer_encoding, req.head.content_length).allocRemaining(arena.allocator(), .limited(1 << 16));
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
        const baton = v.object.get("baton").?;
        const logged = try std.fmt.bufPrint(&f.log[f.n], "{s} {s}", .{ head, if (baton == .string) baton.string else "null" });
        f.log[f.n][logged.len] = 0;
        f.n += 1;
        // A stream's first answer names a replica to keep it on.
        var reply: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&reply,
            \\{{"baton":"b{d}","base_url":"http://127.0.0.1:{d}/replica","results":[{{"type":"ok","response":{{"type":"execute","result":{{"cols":[],"rows":[],"affected_row_count":0,"last_insert_rowid":null}}}}}}]}}
        , .{ f.n, f.port() });
        try req.respond(text, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn entry(f: *FakeHrana, i: usize) []const u8 {
        return std.mem.sliceTo(&f.log[i], 0);
    }
};

test "libsql: the token goes in Authorization; a stream follows the base_url its server names" {
    var fake: FakeHrana = undefined;
    try fake.start();
    defer fake.stop();
    var buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}?authToken=tok", .{fake.port()});
    var pool: db.Pool = try .init(testing.io, testing.allocator, .{ .url = url });
    defer pool.deinit();
    var tx = try pool.begin();
    _ = try tx.exec("INSERT INTO t VALUES (?1)", .{1});
    tx.conn.?.libsql.keep = false; // let close end the stream without a COMMIT round
    tx.deinit();
    try testing.expectEqualStrings("/v2/pipeline Bearer tok null", fake.entry(0));
    try testing.expectEqualStrings("/replica/v2/pipeline Bearer tok b1", fake.entry(1));
}
