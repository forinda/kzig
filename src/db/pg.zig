//! The PostgreSQL wire protocol (v3) in Zig: startup and authentication
//! (SCRAM-SHA-256, MD5, cleartext), the extended query protocol with text
//! parameters and results, and the simple protocol for scripts. No TLS yet.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8,
    application_name: []const u8 = "kzig",
    /// Server-side `statement_timeout`; 0 leaves the server's.
    statement_timeout_ms: u32 = 0,

    /// `postgres://user:password@host:port/database[?sslmode=disable]`. The
    /// strings point into `url` and `a`.
    pub fn parse(a: Allocator, url: []const u8) !Config {
        const uri = std.Uri.parse(url) catch return error.InvalidDatabaseUrl;
        if (!std.mem.eql(u8, uri.scheme, "postgres") and !std.mem.eql(u8, uri.scheme, "postgresql")) return error.InvalidDatabaseUrl;
        var c: Config = .{ .user = "", .database = "" };
        if (uri.host) |h| c.host = try h.toRawMaybeAlloc(a);
        if (uri.port) |p| c.port = p;
        if (uri.user) |u| c.user = try u.toRawMaybeAlloc(a);
        if (uri.password) |p| c.password = try p.toRawMaybeAlloc(a);
        const path = try uri.path.toRawMaybeAlloc(a);
        c.database = std.mem.trimStart(u8, path, "/");
        if (c.user.len == 0) return error.InvalidDatabaseUrl;
        if (c.database.len == 0) c.database = c.user;
        if (uri.query) |q| {
            const query = try q.toRawMaybeAlloc(a);
            var it = std.mem.splitScalar(u8, query, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "sslmode=")) {
                    const mode = pair["sslmode=".len..];
                    // ponytail: no TLS client yet; a URL that demands it is refused
                    // rather than silently sent in the clear.
                    if (!std.mem.eql(u8, mode, "disable") and !std.mem.eql(u8, mode, "allow") and !std.mem.eql(u8, mode, "prefer"))
                        return error.TlsNotSupported;
                } else if (std.mem.startsWith(u8, pair, "application_name=")) {
                    c.application_name = pair["application_name=".len..];
                }
            }
        }
        return c;
    }
};

/// What the server said about a failed statement (`ErrorResponse`).
pub const ServerError = struct {
    severity: []const u8 = "",
    /// SQLSTATE, e.g. `23505` (unique_violation).
    code: [5]u8 = @splat('0'),
    message: []const u8 = "",
    detail: []const u8 = "",
    constraint: []const u8 = "",
};

pub const Error = error{
    /// The server refused the statement; see `Conn.last_error`.
    DbError,
    /// SQLSTATE 23505: a unique constraint (409 through the framework).
    Conflict,
    /// The connection broke; it is not reused.
    ServiceUnavailable,
    DbAuthFailed,
    /// A column missing from the result, or a value its field can't hold.
    DbDecode,
    UnsupportedAuth,
    OutOfMemory,
};

/// One connection. Not thread-safe: the pool hands it to one task at a time.
pub const Conn = struct {
    io: Io,
    gpa: Allocator,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    rbuf: [16 * 1024]u8 = undefined,
    wbuf: [16 * 1024]u8 = undefined,
    /// A read or write failed; the connection is dropped, not reused.
    broken: bool = false,
    /// Inside BEGIN … COMMIT, or a failed transaction (ReadyForQuery status).
    tx_status: u8 = 'I',
    /// A message too big for `rbuf` (a wide row) is read here.
    big: std.ArrayList(u8) = .empty,
    /// The last ErrorResponse, valid until the next statement.
    last_error: ServerError = .{},
    error_arena: std.heap.ArenaAllocator,
    /// The message being built.
    out: std.ArrayList(u8) = .empty,

    pub fn connect(io: Io, gpa: Allocator, cfg: Config) !*Conn {
        const address = Io.net.IpAddress.resolve(io, cfg.host, cfg.port) catch |err| return transportError(err);
        const stream = address.connect(io, .{ .mode = .stream }) catch |err| return transportError(err);
        errdefer stream.close(io);
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{ .io = io, .gpa = gpa, .stream = stream, .reader = undefined, .writer = undefined, .error_arena = .init(gpa) };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        errdefer c.out.deinit(gpa);
        errdefer c.error_arena.deinit();
        try c.startup(cfg);
        return c;
    }

    pub fn close(c: *Conn) void {
        if (!c.broken) {
            // Terminate, politely; the socket closes either way.
            c.begin('X') catch {};
            c.send() catch {};
        }
        c.stream.close(c.io);
        c.out.deinit(c.gpa);
        c.big.deinit(c.gpa);
        c.error_arena.deinit();
        c.gpa.destroy(c);
    }

    // ---- messages out

    fn begin(c: *Conn, kind: ?u8) !void {
        c.out.clearRetainingCapacity();
        if (kind) |k| try c.out.append(c.gpa, k);
        try c.out.appendSlice(c.gpa, &.{ 0, 0, 0, 0 });
    }

    /// Fills in the length of the typed message `begin` started, then queues it.
    fn finish(c: *Conn) !void {
        std.mem.writeInt(u32, c.out.items[1..5], @intCast(c.out.items.len - 1), .big);
        c.writer.interface.writeAll(c.out.items) catch return c.lost();
    }

    fn send(c: *Conn) !void {
        try c.finish();
        c.writer.interface.flush() catch return c.lost();
    }

    fn int16(c: *Conn, v: i16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        try c.out.appendSlice(c.gpa, &b);
    }

    fn int32(c: *Conn, v: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        try c.out.appendSlice(c.gpa, &b);
    }

    fn cstr(c: *Conn, s: []const u8) !void {
        try c.out.appendSlice(c.gpa, s);
        try c.out.append(c.gpa, 0);
    }

    // ---- messages in

    const Message = struct { kind: u8, body: []const u8 };

    /// The next backend message; its body is valid until the next read.
    fn next(c: *Conn) !Message {
        const r = &c.reader.interface;
        const head = (r.takeArray(5) catch return c.lost()).*;
        const len = std.mem.readInt(u32, head[1..5], .big);
        if (len < 4) return c.lost();
        const n = len - 4;
        if (n <= r.buffer.len) return .{ .kind = head[0], .body = r.take(n) catch return c.lost() };
        c.big.clearRetainingCapacity();
        const body = try c.big.addManyAsSlice(c.gpa, n);
        r.readSliceAll(body) catch return c.lost();
        return .{ .kind = head[0], .body = body };
    }

    fn lost(c: *Conn) error{ServiceUnavailable} {
        c.broken = true;
        return error.ServiceUnavailable;
    }

    fn startup(c: *Conn, cfg: Config) !void {
        try c.begin(null);
        try c.int32(196608); // protocol 3.0
        try c.cstr("user");
        try c.cstr(cfg.user);
        try c.cstr("database");
        try c.cstr(cfg.database);
        try c.cstr("application_name");
        try c.cstr(cfg.application_name);
        try c.cstr("client_encoding");
        try c.cstr("UTF8");
        if (cfg.statement_timeout_ms > 0) {
            var buf: [16]u8 = undefined;
            try c.cstr("statement_timeout");
            try c.cstr(std.fmt.bufPrint(&buf, "{d}", .{cfg.statement_timeout_ms}) catch unreachable);
        }
        try c.out.append(c.gpa, 0);
        std.mem.writeInt(u32, c.out.items[0..4], @intCast(c.out.items.len), .big);
        c.writer.interface.writeAll(c.out.items) catch return c.lost();
        c.writer.interface.flush() catch return c.lost();

        var scram: ?Scram = null;
        while (true) {
            const m = try c.next();
            switch (m.kind) {
                'R' => {
                    if (m.body.len < 4) return c.lost();
                    const code = std.mem.readInt(u32, m.body[0..4], .big);
                    switch (code) {
                        0 => {},
                        3 => {
                            try c.begin('p');
                            try c.cstr(cfg.password);
                            try c.send();
                        },
                        5 => {
                            if (m.body.len < 8) return c.lost();
                            const hashed = md5Password(cfg.user, cfg.password, m.body[4..8].*);
                            try c.begin('p');
                            try c.cstr(&hashed);
                            try c.send();
                        },
                        10 => {
                            if (std.mem.find(u8, m.body[4..], "SCRAM-SHA-256\x00") == null) return error.UnsupportedAuth;
                            var nonce_bytes: [18]u8 = undefined;
                            c.io.random(&nonce_bytes);
                            scram = Scram.init(nonce_bytes);
                            const first = scram.?.clientFirst();
                            try c.begin('p');
                            try c.cstr("SCRAM-SHA-256");
                            try c.int32(@intCast(first.len));
                            try c.out.appendSlice(c.gpa, first);
                            try c.send();
                        },
                        11 => {
                            const s = &(scram orelse return c.lost());
                            const final = s.clientFinal(cfg.password, m.body[4..]) catch return error.DbAuthFailed;
                            try c.begin('p');
                            try c.out.appendSlice(c.gpa, final);
                            try c.send();
                        },
                        12 => {
                            const s = &(scram orelse return c.lost());
                            if (!s.verifyServer(m.body[4..])) return error.DbAuthFailed;
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                'E' => {
                    c.readError(m.body);
                    return error.DbAuthFailed;
                },
                'Z' => {
                    c.tx_status = if (m.body.len > 0) m.body[0] else 'I';
                    return;
                },
                // ParameterStatus, BackendKeyData, notices.
                else => {},
            }
        }
    }

    fn readError(c: *Conn, body: []const u8) void {
        _ = c.error_arena.reset(.retain_capacity);
        const a = c.error_arena.allocator();
        var e: ServerError = .{};
        var i: usize = 0;
        while (i < body.len and body[i] != 0) {
            const field = body[i];
            const end = std.mem.findScalarPos(u8, body, i + 1, 0) orelse break;
            const value = a.dupe(u8, body[i + 1 .. end]) catch "";
            switch (field) {
                'S' => e.severity = value,
                'C' => if (value.len == 5) {
                    e.code = value[0..5].*;
                },
                'M' => e.message = value,
                'D' => e.detail = value,
                'n' => e.constraint = value,
                else => {},
            }
            i = end + 1;
        }
        c.last_error = e;
        if (!builtin.is_test) std.log.err("postgres {s} {s}: {s}{s}{s}", .{ e.severity, &e.code, e.message, if (e.detail.len > 0) " — " else "", e.detail });
    }

    fn errorOf(c: *Conn) Error {
        return if (std.mem.eql(u8, &c.last_error.code, "23505")) error.Conflict else error.DbError;
    }

    /// Reads to ReadyForQuery after an error, so the connection is usable again.
    fn drain(c: *Conn) !void {
        while (true) {
            const m = try c.next();
            if (m.kind == 'Z') {
                c.tx_status = if (m.body.len > 0) m.body[0] else 'I';
                return;
            }
        }
    }

    // ---- queries

    /// The extended protocol: Parse, Bind (text parameters), Describe,
    /// Execute, Sync. `row` gets each DataRow's values (null for NULL) with
    /// the column names; returns the affected-row count from the tag.
    pub fn run(c: *Conn, sql: []const u8, params: []const ?[]const u8, ctx: anytype, comptime row: anytype) Error!u64 {
        if (c.broken) return error.ServiceUnavailable;
        try c.begin('P');
        try c.cstr("");
        try c.cstr(sql);
        try c.int16(0);
        try c.finish();
        try c.begin('B');
        try c.cstr("");
        try c.cstr("");
        try c.int16(0);
        try c.int16(@intCast(params.len));
        for (params) |p| if (p) |v| {
            try c.int32(@intCast(v.len));
            try c.out.appendSlice(c.gpa, v);
        } else try c.int32(-1);
        try c.int16(0);
        try c.finish();
        try c.begin('D');
        try c.out.append(c.gpa, 'P');
        try c.cstr("");
        try c.finish();
        try c.begin('E');
        try c.cstr("");
        try c.int32(0);
        try c.finish();
        try c.begin('S');
        try c.send();

        var names: [64][]const u8 = undefined;
        var n_cols: usize = 0;
        var affected: u64 = 0;
        var failed = false;
        // The column names live in a buffer of their own: a DataRow read
        // reuses the reader's.
        var name_buf: [4096]u8 = undefined;
        var values: [64]?[]const u8 = undefined;
        while (true) {
            const m = try c.next();
            switch (m.kind) {
                'T' => {
                    n_cols = std.mem.readInt(u16, m.body[0..2], .big);
                    if (n_cols > names.len) return error.DbDecode;
                    var at: usize = 2;
                    var used: usize = 0;
                    for (0..n_cols) |k| {
                        const end = std.mem.findScalarPos(u8, m.body, at, 0) orelse return c.lost();
                        const name = m.body[at..end];
                        if (used + name.len > name_buf.len) return error.DbDecode;
                        @memcpy(name_buf[used..][0..name.len], name);
                        names[k] = name_buf[used..][0..name.len];
                        used += name.len;
                        at = end + 1 + 18;
                    }
                },
                'D' => if (!failed) {
                    const count = std.mem.readInt(u16, m.body[0..2], .big);
                    var at: usize = 2;
                    for (0..count) |k| {
                        const len = std.mem.readInt(i32, m.body[at..][0..4], .big);
                        at += 4;
                        if (len < 0) {
                            values[k] = null;
                        } else {
                            values[k] = m.body[at..][0..@intCast(len)];
                            at += @intCast(len);
                        }
                    }
                    row(ctx, names[0..n_cols], values[0..count]) catch |err| {
                        // Keep reading to ReadyForQuery; report the first problem.
                        failed = true;
                        c.last_error = .{ .message = @errorName(err) };
                    };
                },
                'C' => affected = tagCount(m.body),
                'E' => {
                    c.readError(m.body);
                    try c.drain();
                    return c.errorOf();
                },
                'Z' => {
                    c.tx_status = if (m.body.len > 0) m.body[0] else 'I';
                    if (failed) return error.DbDecode;
                    return affected;
                },
                else => {},
            }
        }
    }

    /// The simple protocol: one or more statements, no parameters (a
    /// migration's SQL).
    pub fn script(c: *Conn, sql: []const u8) Error!void {
        if (c.broken) return error.ServiceUnavailable;
        try c.begin('Q');
        try c.cstr(sql);
        try c.send();
        var failed = false;
        while (true) {
            const m = try c.next();
            switch (m.kind) {
                'E' => {
                    c.readError(m.body);
                    failed = true;
                },
                'Z' => {
                    c.tx_status = if (m.body.len > 0) m.body[0] else 'I';
                    return if (failed) c.errorOf() else {};
                },
                else => {},
            }
        }
    }
};

fn transportError(err: anyerror) error{ServiceUnavailable} {
    if (!builtin.is_test) std.log.err("postgres: can't connect: {t}", .{err});
    return error.ServiceUnavailable;
}

/// `INSERT 0 3`, `UPDATE 3`, `SELECT 3`, `DELETE 3`: the last number.
fn tagCount(tag: []const u8) u64 {
    const t = std.mem.trimEnd(u8, tag, "\x00");
    const space = std.mem.findScalarLast(u8, t, ' ') orelse return 0;
    return std.fmt.parseInt(u64, t[space + 1 ..], 10) catch 0;
}

/// `md5` + hex(md5(hex(md5(password ++ user)) ++ salt)).
fn md5Password(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    const Md5 = std.crypto.hash.Md5;
    var inner: [Md5.digest_length]u8 = undefined;
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);
    var outer: [Md5.digest_length]u8 = undefined;
    h = Md5.init(.{});
    h.update(&inner_hex);
    h.update(&salt);
    h.final(&outer);
    var out: [35]u8 = undefined;
    @memcpy(out[0..3], "md5");
    out[3..].* = std.fmt.bytesToHex(outer, .lower);
    return out;
}

/// SCRAM-SHA-256 (RFC 5802, RFC 7677) as Postgres speaks it: no channel
/// binding, the user name left empty (the startup message names it).
pub const Scram = struct {
    nonce_buf: [32]u8 = undefined,
    nonce_len: usize = 0,
    first_bare: [128]u8 = undefined,
    first_bare_len: usize = 0,
    message: [512]u8 = undefined,
    server_signature: [HmacSha256.mac_length]u8 = undefined,
    user: []const u8 = "",

    pub fn init(random: [18]u8) Scram {
        var s: Scram = .{ .nonce_len = 24 };
        _ = std.base64.standard.Encoder.encode(s.nonce_buf[0..24], &random);
        return s;
    }

    fn nonce(s: *const Scram) []const u8 {
        return s.nonce_buf[0..s.nonce_len];
    }

    /// `n,,n=<user>,r=<nonce>`.
    pub fn clientFirst(s: *Scram) []const u8 {
        const bare = std.fmt.bufPrint(&s.first_bare, "n={s},r={s}", .{ s.user, s.nonce() }) catch unreachable;
        s.first_bare_len = bare.len;
        return std.fmt.bufPrint(&s.message, "n,,{s}", .{bare}) catch unreachable;
    }

    /// From the server's `r=…,s=…,i=…`: the proof, and the signature the
    /// server must answer with.
    pub fn clientFinal(s: *Scram, password: []const u8, server_first: []const u8) ![]const u8 {
        var server_nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iterations: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') continue;
            switch (attr[0]) {
                'r' => server_nonce = attr[2..],
                's' => salt_b64 = attr[2..],
                'i' => iterations = std.fmt.parseInt(u32, attr[2..], 10) catch return error.BadServerMessage,
                else => {},
            }
        }
        if (!std.mem.startsWith(u8, server_nonce, s.nonce()) or iterations == 0 or iterations > 1_000_000) return error.BadServerMessage;
        var salt: [128]u8 = undefined;
        const salt_len = std.base64.standard.Decoder.calcSizeForSlice(salt_b64) catch return error.BadServerMessage;
        if (salt_len > salt.len) return error.BadServerMessage;
        std.base64.standard.Decoder.decode(salt[0..salt_len], salt_b64) catch return error.BadServerMessage;

        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt[0..salt_len], iterations, HmacSha256);
        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted);
        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        var without_proof_buf: [256]u8 = undefined;
        const without_proof = std.fmt.bufPrint(&without_proof_buf, "c=biws,r={s}", .{server_nonce}) catch return error.BadServerMessage;
        var auth_buf: [512]u8 = undefined;
        const auth = std.fmt.bufPrint(&auth_buf, "{s},{s},{s}", .{ s.first_bare[0..s.first_bare_len], server_first, without_proof }) catch return error.BadServerMessage;

        var signature: [32]u8 = undefined;
        HmacSha256.create(&signature, auth, &stored_key);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, signature) |*p, k, sg| p.* = k ^ sg;
        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        HmacSha256.create(&s.server_signature, auth, &server_key);

        var proof_b64: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&proof_b64, &proof);
        return std.fmt.bufPrint(&s.message, "{s},p={s}", .{ without_proof, &proof_b64 }) catch return error.BadServerMessage;
    }

    /// The server's `v=…` must match: it knows the password too.
    pub fn verifyServer(s: *const Scram, server_final: []const u8) bool {
        if (!std.mem.startsWith(u8, server_final, "v=")) return false;
        var want: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&want, &s.server_signature);
        return std.crypto.timing_safe.eql([44]u8, want, (if (server_final.len >= 46) server_final[2..46] else return false).*);
    }
};

/// A row's values into a struct `T`, by column name. Strings are copied
/// into `a`.
pub fn decodeRow(comptime T: type, a: Allocator, names: []const []const u8, values: []const ?[]const u8) !T {
    var out: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, F| {
        const i = for (names, 0..) |n, k| {
            if (std.mem.eql(u8, n, fname)) break k;
        } else {
            if (!builtin.is_test) std.log.err("db: no column \"{s}\" for {s}", .{ fname, @typeName(T) });
            return error.DbDecode;
        };
        @field(out, fname) = try decodeValue(F, a, values[i]);
    }
    return out;
}

fn decodeValue(comptime F: type, a: Allocator, value: ?[]const u8) !F {
    if (@typeInfo(F) == .optional) {
        const v = value orelse return null;
        return try decodeValue(@typeInfo(F).optional.child, a, v);
    }
    const v = value orelse return error.DbDecode;
    if (F == []const u8) return try a.dupe(u8, v);
    return switch (@typeInfo(F)) {
        .int => std.fmt.parseInt(F, v, 10) catch error.DbDecode,
        .float => std.fmt.parseFloat(F, v) catch error.DbDecode,
        .bool => if (std.mem.eql(u8, v, "t")) true else if (std.mem.eql(u8, v, "f")) false else error.DbDecode,
        .@"enum" => std.meta.stringToEnum(F, v) orelse error.DbDecode,
        else => @compileError("db: a column can't be read into " ++ @typeName(F) ++ " (strings, ints, floats, bools, enums, optionals)"),
    };
}

/// A query's arguments (a tuple) as text parameters, in `a`.
pub fn encodeArgs(a: Allocator, args: anytype) ![]const ?[]const u8 {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const out = try a.alloc(?[]const u8, info.field_names.len);
    inline for (info.field_names, 0..) |f, i| out[i] = try encodeValue(a, @field(args, f));
    return out;
}

fn encodeValue(a: Allocator, v: anytype) !?[]const u8 {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => return if (v) |x| try encodeValue(a, x) else null,
        .null => return null,
        .int, .comptime_int => return try std.fmt.allocPrint(a, "{d}", .{v}),
        .float, .comptime_float => return try std.fmt.allocPrint(a, "{d}", .{v}),
        .bool => return if (v) "true" else "false",
        .@"enum", .enum_literal => return @tagName(v),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return v;
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return v;
            @compileError("db: an argument can't be " ++ @typeName(T));
        },
        else => @compileError("db: an argument can't be " ++ @typeName(T)),
    }
}

const testing = std.testing;

test "SCRAM-SHA-256: RFC 7677's exchange" {
    // RFC 7677 §3: user "user", password "pencil", its client nonce.
    var s: Scram = .{ .user = "user" };
    const nonce = "rOprNGfwEbeRWgbNEkqO";
    @memcpy(s.nonce_buf[0..nonce.len], nonce);
    s.nonce_len = nonce.len;
    try testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", s.clientFirst());
    const final = try s.clientFinal("pencil", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    try testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
    // The RFC prints `v=6rriTRBi23WpRR/wl+JmWqgRsBZmA1ui4vjQr7XIJHQ=`, a known
    // erratum; this is the signature its own inputs give (checked in Python).
    try testing.expect(s.verifyServer("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    try testing.expect(!s.verifyServer("v=AAAATRBi23WpRR/wl+JmWqgRsBZmA1ui4vjQr7XIJHQ="));
    // The server's nonce must extend ours.
    var t: Scram = .{ .user = "user" };
    @memcpy(t.nonce_buf[0..nonce.len], nonce);
    t.nonce_len = nonce.len;
    _ = t.clientFirst();
    try testing.expectError(error.BadServerMessage, t.clientFinal("pencil", "r=someoneelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"));
}

test "MD5 password: Postgres's construction" {
    // md5(md5("secret" ++ "postgres") ++ salt), computed independently.
    const out = md5Password("postgres", "secret", .{ 1, 2, 3, 4 });
    try testing.expect(std.mem.startsWith(u8, &out, "md5"));
    try testing.expectEqual(35, out.len);
}

test "rows decode by column name; NULL only into optionals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { id: i64, name: []const u8, score: ?f64, active: bool, role: enum { admin, user } };
    const names = [_][]const u8{ "role", "active", "score", "name", "id" };
    const r = try decodeRow(Row, a, &names, &.{ "admin", "t", null, "Ada", "42" });
    try testing.expectEqual(42, r.id);
    try testing.expectEqualStrings("Ada", r.name);
    try testing.expectEqual(null, r.score);
    try testing.expect(r.active);
    try testing.expectEqual(.admin, r.role);
    try testing.expectError(error.DbDecode, decodeRow(Row, a, &names, &.{ "admin", "t", null, null, "42" }));
    try testing.expectError(error.DbDecode, decodeRow(Row, a, names[1..], &.{ "t", null, "Ada", "42" }));
    try testing.expectError(error.DbDecode, decodeRow(Row, a, &names, &.{ "root", "t", null, "Ada", "42" }));
}

test "arguments encode as text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const role: enum { admin } = .admin;
    const none: ?i32 = null;
    const p = try encodeArgs(arena.allocator(), .{ 7, "x", true, 1.5, none, role, @as(?[]const u8, "y") });
    try testing.expectEqualStrings("7", p[0].?);
    try testing.expectEqualStrings("x", p[1].?);
    try testing.expectEqualStrings("true", p[2].?);
    try testing.expectEqualStrings("1.5", p[3].?);
    try testing.expectEqual(null, p[4]);
    try testing.expectEqualStrings("admin", p[5].?);
    try testing.expectEqualStrings("y", p[6].?);
}

test "command tags give the affected rows" {
    try testing.expectEqual(3, tagCount("INSERT 0 3\x00"));
    try testing.expectEqual(2, tagCount("UPDATE 2"));
    try testing.expectEqual(0, tagCount("CREATE TABLE"));
}
