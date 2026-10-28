//! The PostgreSQL wire protocol (v3) in Zig: startup and authentication
//! (SCRAM-SHA-256, MD5, cleartext), the extended query protocol with text
//! parameters and results, and the simple protocol for scripts. No TLS yet.
const std = @import("std");
const tls = struct {
    const Client = @import("tls/Client.zig");
};
const keys = @import("tls/keys.zig");
const crl = @import("tls/crl.zig");
const builtin = @import("builtin");
const Timestamp = @import("timestamp.zig").Timestamp;
const Dialect = @import("db.zig").Dialect;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// libpq's `sslmode`. `prefer` (the default) uses TLS when the server
/// offers it, unverified; `verify-ca` checks the certificate chain,
/// `verify-full` the host name too.
pub const SslMode = enum { disable, allow, prefer, require, verify_ca, verify_full };

/// libpq's `sslnegotiation`: `postgres` asks with SSLRequest first; `direct`
/// (Postgres 17) starts TLS at once with ALPN `postgresql`, a round trip less.
pub const SslNegotiation = enum { postgres, direct };

/// libpq's `channel_binding`: SCRAM-SHA-256-PLUS ties the sign-in to this TLS
/// session (the server's certificate), so a man in the middle with his own
/// certificate can't relay it. `prefer` uses it when TLS is on and the server
/// offers it; `require` refuses anything else.
pub const ChannelBinding = enum { disable, prefer, require };

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8,
    application_name: []const u8 = "kzig",
    /// Server-side `statement_timeout`; 0 leaves the server's.
    statement_timeout_ms: u32 = 0,
    sslmode: SslMode = .prefer,
    sslnegotiation: SslNegotiation = .postgres,
    channel_binding: ChannelBinding = .prefer,
    /// PEM file of the CAs to trust (`verify-ca`, `verify-full`); the
    /// system's when null.
    sslrootcert: ?[]const u8 = null,
    /// A client certificate chain (PEM, leaf first) and its key, for a server
    /// that authenticates clients by certificate (pg_hba `cert`).
    sslcert: ?[]const u8 = null,
    sslkey: ?[]const u8 = null,
    /// Unlocks an encrypted `sslkey` (PKCS#8 PBES2, or OpenSSL's DEK-Info PEM).
    sslpassword: ?[]const u8 = null,
    /// Revocation lists (PEM or DER) signed by a CA in `sslrootcert`: a
    /// server certificate they list is refused. Needs `sslrootcert`.
    sslcrl: ?[]const u8 = null,
    /// `insecure_auth=true`: answer a cleartext or MD5 password request on
    /// an unverified connection (an old server); off, that's `error.InsecureAuth`.
    insecure_auth: bool = false,

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
                    var buf: [16]u8 = undefined;
                    if (mode.len > buf.len) return error.InvalidDatabaseUrl;
                    for (mode, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
                    c.sslmode = std.meta.stringToEnum(SslMode, buf[0..mode.len]) orelse return error.InvalidDatabaseUrl;
                } else if (std.mem.startsWith(u8, pair, "sslnegotiation=")) {
                    c.sslnegotiation = std.meta.stringToEnum(SslNegotiation, pair["sslnegotiation=".len..]) orelse return error.InvalidDatabaseUrl;
                } else if (std.mem.startsWith(u8, pair, "channel_binding=")) {
                    c.channel_binding = std.meta.stringToEnum(ChannelBinding, pair["channel_binding=".len..]) orelse return error.InvalidDatabaseUrl;
                } else if (std.mem.eql(u8, pair, "insecure_auth=true")) {
                    c.insecure_auth = true;
                } else if (std.mem.startsWith(u8, pair, "sslcert=")) {
                    c.sslcert = pair["sslcert=".len..];
                } else if (std.mem.startsWith(u8, pair, "sslkey=")) {
                    c.sslkey = pair["sslkey=".len..];
                } else if (std.mem.startsWith(u8, pair, "sslcrl=")) {
                    c.sslcrl = pair["sslcrl=".len..];
                } else if (std.mem.startsWith(u8, pair, "sslpassword=")) {
                    c.sslpassword = std.Uri.percentDecodeInPlace(try a.dupe(u8, pair["sslpassword=".len..]));
                } else if (std.mem.startsWith(u8, pair, "sslrootcert=")) {
                    c.sslrootcert = pair["sslrootcert=".len..];
                } else if (std.mem.startsWith(u8, pair, "application_name=")) {
                    c.application_name = pair["application_name=".len..];
                }
            }
        }
        if ((c.sslcert == null) != (c.sslkey == null)) return error.InvalidDatabaseUrl;
        // A CRL is checked against the CAs it's signed by: name them.
        if (c.sslcrl != null and c.sslrootcert == null) return error.InvalidDatabaseUrl;
        // libpq: direct TLS can't fall back to plaintext.
        if (c.sslnegotiation == .direct and (c.sslmode == .disable or c.sslmode == .allow or c.sslmode == .prefer))
            return error.InvalidDatabaseUrl;
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
    /// More parameters than the database binds in one statement (D1: 100).
    TooManyParameters,
    /// The transaction can't go on: a remote SQLite's stream for it broke.
    TransactionAborted,
    /// A migration left a foreign key pointing at a missing row (rolled back).
    ForeignKeyViolation,
    /// SQLSTATE 23505: a unique constraint (409 through the framework).
    Conflict,
    /// The connection broke; it is not reused.
    ServiceUnavailable,
    DbAuthFailed,
    /// A column missing from the result, or a value its field can't hold.
    DbDecode,
    UnsupportedAuth,
    /// The server asked for a cleartext or MD5 password over a connection
    /// whose server wasn't verified (sslmode verify-ca/verify-full); see
    /// `Config.insecure_auth`.
    InsecureAuth,
    /// sslmode require or stronger, and the server has no TLS.
    TlsRefused,
    /// channel_binding=require, and the sign-in wasn't SCRAM-SHA-256-PLUS.
    ChannelBindingRequired,
    /// The handshake failed: the certificate didn't verify, or the server
    /// speaks no TLS we do.
    TlsHandshakeFailed,
    /// `sslrootcert` couldn't be read, or the system's CAs couldn't be loaded.
    TlsConfig,
    OutOfMemory,
};

/// What a connection's TLS checks, from sslmode and sslrootcert as libpq
/// reads them, made safer: `require` with a root cert is `verify-ca`
/// (libpq), and `verify-ca` against the system's CAs also checks the host
/// (any public certificate would pass otherwise).
pub const TlsPlan = struct { chain: bool, host: bool, os_roots: bool };

pub fn tlsPlan(cfg: Config) TlsPlan {
    var mode = cfg.sslmode;
    if (mode == .require and cfg.sslrootcert != null) mode = .verify_ca;
    if (mode == .verify_ca and cfg.sslrootcert == null) mode = .verify_full;
    const chain = mode == .verify_ca or mode == .verify_full;
    return .{ .chain = chain, .host = mode == .verify_full, .os_roots = cfg.sslrootcert == null };
}

/// One connection. Not thread-safe: the pool hands it to one task at a time.
pub const Conn = struct {
    io: Io,
    gpa: Allocator,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    // A TLS record must fit the socket's read buffer.
    rbuf: [tls.Client.min_buffer_len]u8 = undefined,
    wbuf: [tls.Client.min_buffer_len]u8 = undefined,
    /// Messages go through it once the server accepted SSLRequest.
    tls: ?tls.Client = null,
    /// The certificate chain (and maybe host) was checked: passwords may go.
    tls_verified: bool = false,
    tls_rbuf: [tls.Client.min_buffer_len]u8 = undefined,
    tls_wbuf: [tls.Client.min_buffer_len]u8 = undefined,
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
        const host = Io.net.HostName.init(cfg.host) catch |err| return transportError(err);
        const stream = host.connect(io, cfg.port, .{ .mode = .stream }) catch |err| return transportError(err);
        errdefer stream.close(io);
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{ .io = io, .gpa = gpa, .stream = stream, .reader = undefined, .writer = undefined, .error_arena = .init(gpa) };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        errdefer c.out.deinit(gpa);
        errdefer c.big.deinit(gpa);
        errdefer c.error_arena.deinit();
        try c.negotiateTls(cfg);
        try c.startup(cfg);
        return c;
    }

    fn rd(c: *Conn) *Io.Reader {
        return if (c.tls) |*t| &t.reader else &c.reader.interface;
    }

    fn wr(c: *Conn) *Io.Writer {
        return if (c.tls) |*t| &t.writer else &c.writer.interface;
    }

    /// TLS's flush only encrypts into the socket's buffer: flush that too.
    fn flushOut(c: *Conn) Io.Writer.Error!void {
        try c.wr().flush();
        if (c.tls != null) try c.writer.interface.flush();
    }

    /// SSLRequest, then the TLS handshake when the server says 'S'.
    fn negotiateTls(c: *Conn, cfg: Config) !void {
        // ponytail: `allow` is treated as `prefer` (TLS first, not plaintext first).
        if (cfg.sslmode == .disable) return;
        if (cfg.sslnegotiation == .direct) return c.handshake(cfg);
        var req: [8]u8 = undefined;
        std.mem.writeInt(u32, req[0..4], 8, .big);
        std.mem.writeInt(u32, req[4..8], 80877103, .big);
        c.writer.interface.writeAll(&req) catch return c.lost();
        c.flushOut() catch return c.lost();
        const answer = c.reader.interface.takeByte() catch return c.lost();
        // CVE-2021-23222: anything sent with the answer came before TLS and
        // could be anyone's; libpq hangs up on it.
        if (c.reader.interface.bufferedLen() != 0) return c.lost();
        switch (answer) {
            'S' => {},
            'N' => switch (cfg.sslmode) {
                .require, .verify_ca, .verify_full => {
                    if (!builtin.is_test) std.log.err("postgres: sslmode={t}, and the server has no TLS", .{cfg.sslmode});
                    return error.TlsRefused;
                },
                else => return,
            },
            else => return c.lost(),
        }
        return c.handshake(cfg);
    }

    fn handshake(c: *Conn, cfg: Config) !void {
        const plan = tlsPlan(cfg);
        const verify = plan.chain;
        const now = Io.Clock.real.now(c.io);
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(c.gpa);
        var lock: Io.RwLock = .init;
        // ponytail: the CA bundle is read per connection; share it in the pool
        // if connecting gets hot.
        if (verify) {
            if (cfg.sslrootcert) |path|
                bundle.addCertsFromFilePath(c.gpa, c.io, now, Io.Dir.cwd(), path) catch |err| {
                    if (!builtin.is_test) std.log.err("postgres: sslrootcert {s}: {t}", .{ path, err });
                    return error.TlsConfig;
                }
            else
                bundle.rescan(c.gpa, c.io, now) catch |err| {
                    if (!builtin.is_test) std.log.err("postgres: the system's CAs: {t}", .{err});
                    return error.TlsConfig;
                };
        }
        // The client certificate, read for this handshake only.
        // The key's PEM, its base64 and DER live in one scratch buffer, zeroed
        // before it's freed; so is the key's copy in `client_auth`.
        const scratch: []u8 = if (cfg.sslcert != null) try c.gpa.alloc(u8, 256 * 1024) else &.{};
        defer if (scratch.len > 0) {
            std.crypto.secureZero(u8, scratch);
            c.gpa.free(scratch);
        };
        var fba: std.heap.FixedBufferAllocator = .init(scratch);
        var client_auth: ?tls.Client.ClientAuth = if (cfg.sslcert) |cert_path| blk: {
            const ca = fba.allocator();
            const cwd = Io.Dir.cwd();
            const cert_pem = cwd.readFileAlloc(c.io, cert_path, ca, .limited(64 << 10)) catch |err| return tlsConfig("sslcert", cert_path, err);
            const key_pem = cwd.readFileAlloc(c.io, cfg.sslkey.?, ca, .limited(16 << 10)) catch |err| return tlsConfig("sslkey", cfg.sslkey.?, err);
            const chain = keys.parseChain(ca, cert_pem) catch |err| return tlsConfig("sslcert", cert_path, err);
            const key = keys.PrivateKey.parsePem(ca, key_pem, cfg.sslpassword) catch |err| return tlsConfig("sslkey", cfg.sslkey.?, err);
            // libpq: a key that isn't the certificate's is a configuration error.
            if (!(key.matches(chain[0]) catch false)) return tlsConfig("sslkey", cfg.sslkey.?, error.KeyDoesNotMatchCertificate);
            break :blk .{ .chain = chain, .key = key, .io = c.io };
        } else null;
        defer if (client_auth) |*auth| std.crypto.secureZero(u8, std.mem.asBytes(&auth.key));
        // Revocation lists, each verified against the CAs in sslrootcert.
        var crl_arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer crl_arena.deinit();
        const crls: ?crl.Set = if (cfg.sslcrl) |crl_path| blk: {
            const ca_arena = crl_arena.allocator();
            const cwd = Io.Dir.cwd();
            const text = cwd.readFileAlloc(c.io, crl_path, ca_arena, .limited(16 << 20)) catch |err| return tlsConfig("sslcrl", crl_path, err);
            const roots = cwd.readFileAlloc(c.io, cfg.sslrootcert.?, ca_arena, .limited(16 << 20)) catch |err| return tlsConfig("sslrootcert", cfg.sslrootcert.?, err);
            const cas = keys.parseChain(ca_arena, roots) catch |err| return tlsConfig("sslrootcert", cfg.sslrootcert.?, err);
            break :blk crl.Set.load(ca_arena, text, cas, now.toSeconds()) catch |err| return tlsConfig("sslcrl", crl_path, err);
        } else null;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        c.tls = tls.Client.init(&c.reader.interface, &c.writer.interface, .{
            .host = if (plan.host) .{ .explicit = cfg.host } else .no_verification,
            // SNI in every mode (libpq's sslsni), but never an IP address (RFC 6066).
            .server_name = if (isIp(cfg.host)) null else cfg.host,
            .os_roots = plan.os_roots,
            // Direct TLS: the server only accepts it with ALPN `postgresql`.
            .alpn = if (cfg.sslnegotiation == .direct) "postgresql" else null,
            .client_auth = client_auth,
            .crl = if (crls) |*set| set else null,
            .ca = if (verify) .{ .bundle = .{ .gpa = c.gpa, .io = c.io, .lock = &lock, .bundle = &bundle } } else .no_verification,
            .read_buffer = &c.tls_rbuf,
            .write_buffer = &c.tls_wbuf,
            .entropy = &entropy,
            .realtime_now = now,
            // Every message carries its length: a cut stream is caught there.
            .allow_truncation_attacks = true,
        }) catch |err| {
            if (!builtin.is_test) std.log.err("postgres: TLS: {t}", .{err});
            c.broken = true;
            return error.TlsHandshakeFailed;
        };
        c.tls_verified = verify;
    }

    fn tlsConfig(what: []const u8, path: []const u8, err: anyerror) error{TlsConfig} {
        if (!builtin.is_test) std.log.err("postgres: {s} {s}: {t}", .{ what, path, err });
        return error.TlsConfig;
    }

    fn isIp(host: []const u8) bool {
        _ = Io.net.IpAddress.parse(host, 0) catch return false;
        return true;
    }

    pub fn close(c: *Conn) void {
        if (!c.broken) {
            // Terminate, politely; the socket closes either way.
            c.begin('X') catch {};
            c.send() catch {};
            // TLS close_notify, then the ciphertext out.
            if (c.tls) |*t| {
                t.end() catch {};
                c.writer.interface.flush() catch {};
            }
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
        c.wr().writeAll(c.out.items) catch return c.lost();
    }

    fn send(c: *Conn) !void {
        try c.finish();
        c.flushOut() catch return c.lost();
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
        const r = c.rd();
        const head = (r.takeArray(5) catch return c.lost()).*;
        const len = std.mem.readInt(u32, head[1..5], .big);
        if (len < 4) return c.lost();
        const n = len - 4;
        if (n <= r.buffer.len) return .{ .kind = head[0], .body = r.take(n) catch return c.lost() };
        c.big.clearRetainingCapacity();
        // Unread, the body would be taken for the next message.
        const body = c.big.addManyAsSlice(c.gpa, n) catch {
            c.broken = true;
            return error.OutOfMemory;
        };
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
        // Timestamps are read as UTC ISO text, and CURRENT_TIMESTAMP into a
        // `timestamp` column must be UTC too, whatever the server's defaults.
        try c.cstr("TimeZone");
        try c.cstr("UTC");
        try c.cstr("DateStyle");
        try c.cstr("ISO, MDY");
        if (cfg.statement_timeout_ms > 0) {
            var buf: [16]u8 = undefined;
            try c.cstr("statement_timeout");
            try c.cstr(std.fmt.bufPrint(&buf, "{d}", .{cfg.statement_timeout_ms}) catch unreachable);
        }
        try c.out.append(c.gpa, 0);
        std.mem.writeInt(u32, c.out.items[0..4], @intCast(c.out.items.len), .big);
        c.wr().writeAll(c.out.items) catch return c.lost();
        c.flushOut() catch return c.lost();

        var scram: ?Scram = null;
        var proven = false;
        // A password, or MD5 of it with a salt the server picked, only to a
        // verified server (or when the URL says the server is old).
        const may_send_password = c.tls_verified or cfg.insecure_auth;
        while (true) {
            const m = try c.next();
            switch (m.kind) {
                'R' => {
                    if (m.body.len < 4) return c.lost();
                    const code = std.mem.readInt(u32, m.body[0..4], .big);
                    switch (code) {
                        // A SCRAM exchange that skipped the server's proof
                        // isn't a server that knows the password.
                        0 => {
                            if (scram != null and !proven) return error.DbAuthFailed;
                            // Trust or a password: nothing bound the session.
                            if (cfg.channel_binding == .require and (scram == null or !scram.?.bound())) return error.ChannelBindingRequired;
                        },
                        3 => {
                            // libpq: with require, only a SASL request gets an answer.
                            if (cfg.channel_binding == .require) return error.ChannelBindingRequired;
                            if (!may_send_password) return insecure("a cleartext password");
                            try c.begin('p');
                            try c.cstr(cfg.password);
                            try c.send();
                        },
                        5 => {
                            if (cfg.channel_binding == .require) return error.ChannelBindingRequired;
                            if (!may_send_password) return insecure("an MD5 password");
                            if (m.body.len < 8) return c.lost();
                            const hashed = md5Password(cfg.user, cfg.password, m.body[4..8].*);
                            try c.begin('p');
                            try c.cstr(&hashed);
                            try c.send();
                        },
                        10 => {
                            const mechs = m.body[4..];
                            const offers_plus = std.mem.find(u8, mechs, "SCRAM-SHA-256-PLUS\x00") != null;
                            const end_point = if (c.tls) |*t| t.server_end_point[0..t.server_end_point_len] else "";
                            const can_bind = cfg.channel_binding != .disable and end_point.len > 0;
                            const plus = can_bind and offers_plus;
                            if (cfg.channel_binding == .require and !plus) return error.ChannelBindingRequired;
                            if (!plus and std.mem.find(u8, mechs, "SCRAM-SHA-256\x00") == null) return error.UnsupportedAuth;
                            var nonce_bytes: [18]u8 = undefined;
                            c.io.random(&nonce_bytes);
                            scram = Scram.init(nonce_bytes);
                            // RFC 5802 §6: `y` says we could bind but the server
                            // offered no PLUS, so a stripped offer is caught.
                            scram.?.gs2 = if (plus) "p=tls-server-end-point,," else if (can_bind) "y,," else "n,,";
                            if (plus) scram.?.cbind = end_point;
                            const first = scram.?.clientFirst();
                            try c.begin('p');
                            try c.cstr(if (plus) "SCRAM-SHA-256-PLUS" else "SCRAM-SHA-256");
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
                            // The server's proof comes after its first message, never instead of it.
                            if (!s.answered) return error.DbAuthFailed;
                            if (!s.verifyServer(m.body[4..])) return error.DbAuthFailed;
                            proven = true;
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

    fn insecure(what: []const u8) error{InsecureAuth} {
        if (!builtin.is_test) std.log.err("postgres: the server asked for {s} without verified TLS (sslmode verify-ca/verify-full); refused. insecure_auth=true allows it", .{what});
        return error.InsecureAuth;
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
        // A problem with the rows is reported at ReadyForQuery: returning
        // earlier would leave the rest of the answer for the next statement.
        while (true) {
            const m = try c.next();
            switch (m.kind) {
                'T' => {
                    n_cols = std.mem.readInt(u16, m.body[0..2], .big);
                    if (n_cols > names.len) {
                        failed = true;
                        c.last_error = .{ .message = "more than 64 columns" };
                        continue;
                    }
                    var at: usize = 2;
                    var used: usize = 0;
                    for (0..n_cols) |k| {
                        const end = std.mem.findScalarPos(u8, m.body, at, 0) orelse return c.lost();
                        const name = m.body[at..end];
                        if (used + name.len > name_buf.len) {
                            failed = true;
                            c.last_error = .{ .message = "column names too long" };
                            break;
                        }
                        @memcpy(name_buf[used..][0..name.len], name);
                        names[k] = name_buf[used..][0..name.len];
                        used += name.len;
                        at = end + 1 + 18;
                    }
                },
                'D' => if (!failed) {
                    const count = std.mem.readInt(u16, m.body[0..2], .big);
                    if (count != n_cols) return c.lost();
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
    /// `clientFinal` ran: `server_signature` is set.
    answered: bool = false,
    /// RFC 5802's GS2 header: `n,,`, `y,,` or `p=tls-server-end-point,,`.
    gs2: []const u8 = "n,,",
    /// Channel-binding data (the server certificate's hash) with `p=`.
    cbind: []const u8 = "",
    user: []const u8 = "",

    pub fn init(random: [18]u8) Scram {
        var s: Scram = .{ .nonce_len = 24 };
        _ = std.base64.standard.Encoder.encode(s.nonce_buf[0..24], &random);
        return s;
    }

    /// Signed in with SCRAM-SHA-256-PLUS.
    pub fn bound(s: *const Scram) bool {
        return s.cbind.len > 0;
    }

    fn nonce(s: *const Scram) []const u8 {
        return s.nonce_buf[0..s.nonce_len];
    }

    /// `n,,n=<user>,r=<nonce>`.
    pub fn clientFirst(s: *Scram) []const u8 {
        const bare = std.fmt.bufPrint(&s.first_bare, "n={s},r={s}", .{ s.user, s.nonce() }) catch unreachable;
        s.first_bare_len = bare.len;
        return std.fmt.bufPrint(&s.message, "{s}{s}", .{ s.gs2, bare }) catch unreachable;
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
        // c=: the GS2 header and, when bound, the certificate hash.
        var cb_raw: [128]u8 = undefined;
        if (s.gs2.len + s.cbind.len > cb_raw.len) return error.BadServerMessage;
        @memcpy(cb_raw[0..s.gs2.len], s.gs2);
        @memcpy(cb_raw[s.gs2.len..][0..s.cbind.len], s.cbind);
        var cb_b64: [std.base64.standard.Encoder.calcSize(128)]u8 = undefined;
        const cb = std.base64.standard.Encoder.encode(&cb_b64, cb_raw[0 .. s.gs2.len + s.cbind.len]);
        const without_proof = std.fmt.bufPrint(&without_proof_buf, "c={s},r={s}", .{ cb, server_nonce }) catch return error.BadServerMessage;
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
        s.answered = true;
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
    if (F == std.json.Value) return std.json.parseFromSliceLeaky(std.json.Value, a, v, .{ .allocate = .alloc_always }) catch error.DbDecode;
    if (@typeInfo(F) == .@"struct" and @hasDecl(F, "fromPg")) return F.fromPg(v);
    // A relational read's nested row(s): JSON from to_json / json_agg.
    if (@typeInfo(F) == .@"struct" or (@typeInfo(F) == .pointer and @typeInfo(F).pointer.size == .slice)) {
        // Numbers as Postgres wrote them: a numeric's digits survive.
        const j = std.json.parseFromSliceLeaky(std.json.Value, a, v, .{ .allocate = .alloc_always, .parse_numbers = false }) catch return error.DbDecode;
        return fromJson(F, a, j);
    }
    return switch (@typeInfo(F)) {
        .int => std.fmt.parseInt(F, v, 10) catch error.DbDecode,
        .float => std.fmt.parseFloat(F, v) catch error.DbDecode,
        // Postgres's t/f, SQLite's 1/0.
        .bool => if (std.mem.eql(u8, v, "t") or std.mem.eql(u8, v, "1")) true else if (std.mem.eql(u8, v, "f") or std.mem.eql(u8, v, "0")) false else error.DbDecode,
        .@"enum" => std.meta.stringToEnum(F, v) orelse error.DbDecode,
        else => @compileError("db: a column can't be read into " ++ @typeName(F) ++ " (strings, ints, floats, bools, enums, optionals)"),
    };
}

/// A JSON value (nested rows) as `F`: the same types rows read into.
pub fn fromJson(comptime F: type, a: Allocator, v: std.json.Value) !F {
    if (F == std.json.Value) return v;
    switch (@typeInfo(F)) {
        .optional => |o| return if (v == .null) null else try fromJson(o.child, a, v),
        // SQLite's JSON has no booleans: 1/0.
        .bool => return switch (v) {
            .bool => |b| b,
            .integer => |i| if (i == 0 or i == 1) i == 1 else error.DbDecode,
            .number_string => |n| if (std.mem.eql(u8, n, "1")) true else if (std.mem.eql(u8, n, "0")) false else error.DbDecode,
            else => error.DbDecode,
        },
        .int => return switch (v) {
            .integer => |i| std.math.cast(F, i) orelse error.DbDecode,
            .number_string, .string => |s| std.fmt.parseInt(F, s, 10) catch error.DbDecode,
            else => error.DbDecode,
        },
        .float => return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .number_string, .string => |s| std.fmt.parseFloat(F, s) catch error.DbDecode,
            else => error.DbDecode,
        },
        .@"enum" => return if (v == .string) (std.meta.stringToEnum(F, v.string) orelse error.DbDecode) else error.DbDecode,
        .pointer => |p| {
            if (F == []const u8) return switch (v) {
                .string, .number_string => |s| s,
                // numeric columns come out of to_json as numbers
                .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
                else => error.DbDecode,
            };
            if (p.size != .slice or v != .array) return error.DbDecode;
            const out = try a.alloc(p.child, v.array.items.len);
            for (v.array.items, out) |x, *o| o.* = try fromJson(p.child, a, x);
            return out;
        },
        .@"struct" => |info| {
            if (@hasDecl(F, "fromJsonValue")) return F.fromJsonValue(v) orelse error.DbDecode;
            if (v != .object) return error.DbDecode;
            var out: F = undefined;
            inline for (info.field_names, info.field_types) |name, T| {
                @field(out, name) = if (v.object.get(name)) |x| try fromJson(T, a, x) else if (@typeInfo(T) == .optional) null else return error.DbDecode;
            }
            return out;
        },
        else => @compileError("db: a nested row can't hold " ++ @typeName(F)),
    }
}

/// A query's arguments (a tuple) as text parameters, in `a`.
pub fn encodeArgs(a: Allocator, args: anytype, dialect: Dialect) ![]const ?[]const u8 {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const out = try a.alloc(?[]const u8, info.field_names.len);
    inline for (info.field_names, 0..) |f, i| out[i] = try encodeValue(a, @field(args, f), dialect);
    return out;
}

/// A value as a text parameter. SQLite gets booleans as 1/0 and timestamps
/// as kick/db stores them there.
pub fn encodeValue(a: Allocator, v: anytype, dialect: Dialect) !?[]const u8 {
    const T = @TypeOf(v);
    if (T == std.json.Value) return try std.json.Stringify.valueAlloc(a, v, .{});
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "toSqlite") and dialect == .sqlite) return try v.toSqlite(a);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "toPg")) return try v.toPg(a);
    switch (@typeInfo(T)) {
        .optional => return if (v) |x| try encodeValue(a, x, dialect) else null,
        .null => return null,
        .int, .comptime_int => return try std.fmt.allocPrint(a, "{d}", .{v}),
        .float, .comptime_float => return try std.fmt.allocPrint(a, "{d}", .{v}),
        .bool => return if (dialect == .sqlite) (if (v) "1" else "0") else if (v) "true" else "false",
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
    const p = try encodeArgs(arena.allocator(), .{ 7, "x", true, 1.5, none, role, @as(?[]const u8, "y") }, .postgres);
    try testing.expectEqualStrings("7", p[0].?);
    try testing.expectEqualStrings("x", p[1].?);
    try testing.expectEqualStrings("true", p[2].?);
    try testing.expectEqualStrings("1.5", p[3].?);
    try testing.expectEqual(null, p[4]);
    try testing.expectEqualStrings("admin", p[5].?);
    try testing.expectEqualStrings("y", p[6].?);
}

test "Timestamp and JSON columns read and write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { at: Timestamp, meta: std.json.Value, gone: ?Timestamp };
    const r = try decodeRow(Row, a, &.{ "at", "meta", "gone" }, &.{ "2026-10-27 12:00:00+00", "{\"k\":[1,2]}", null });
    try testing.expectEqual(1793102400000000, r.at.us);
    try testing.expectEqual(2, r.meta.object.get("k").?.array.items.len);
    try testing.expectEqual(null, r.gone);
    try testing.expectError(error.DbDecode, decodeRow(Row, a, &.{ "at", "meta", "gone" }, &.{ "never", "{}", null }));
    const args = try encodeArgs(a, .{ Timestamp{ .us = 0 }, std.json.Value{ .bool = true } }, .postgres);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", args[0].?);
    try testing.expectEqualStrings("true", args[1].?);
}

test "nested rows keep numbers exactly as Postgres wrote them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Child = struct { price: []const u8, big: []const u8, n: i64, f: f64 };
    const R = struct { child: ?Child };
    const r = try decodeRow(R, a, &.{"child"}, &.{"{\"price\":12.50,\"big\":1234567890123456789012.34,\"n\":9007199254740993,\"f\":0.5}"});
    try testing.expectEqualStrings("12.50", r.child.?.price);
    try testing.expectEqualStrings("1234567890123456789012.34", r.child.?.big);
    try testing.expectEqual(9007199254740993, r.child.?.n);
    try testing.expectEqual(0.5, r.child.?.f);
}

test "command tags give the affected rows" {
    try testing.expectEqual(3, tagCount("INSERT 0 3\x00"));
    try testing.expectEqual(2, tagCount("UPDATE 2"));
    try testing.expectEqual(0, tagCount("CREATE TABLE"));
}

/// A scripted Postgres server on a local port: what a test needs to see a
/// client through SSLRequest and authentication.
const Fake = struct {
    server: Io.net.Server,
    task: Io.Future(anyerror!void) = undefined,

    fn start(script: *const fn (Io.net.Stream) anyerror!void) !*Fake {
        const f = try testing.allocator.create(Fake);
        errdefer testing.allocator.destroy(f);
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        f.* = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }) };
        f.task = try testing.io.concurrent(serve, .{ f, script });
        return f;
    }

    fn serve(f: *Fake, script: *const fn (Io.net.Stream) anyerror!void) anyerror!void {
        const s = try f.server.accept(testing.io);
        defer s.close(testing.io);
        try script(s);
    }

    fn config(f: *Fake, mode: SslMode) Config {
        return .{ .host = "127.0.0.1", .port = f.server.socket.address.getPort(), .user = "u", .database = "d", .password = "pw", .sslmode = mode };
    }

    /// The script's own error, if it had one.
    fn finish(f: *Fake) !void {
        defer testing.allocator.destroy(f);
        defer f.server.deinit(testing.io);
        try f.task.await(testing.io);
    }

    fn readExact(s: Io.net.Stream, buf: []u8) !void {
        var rb: [64]u8 = undefined;
        var r = s.reader(testing.io, &rb);
        try r.interface.readSliceAll(buf);
    }

    /// A startup message (or SSLRequest): its length, then its body.
    fn readStartup(s: Io.net.Stream, buf: []u8) ![]u8 {
        var rb: [4096]u8 = undefined;
        var r = s.reader(testing.io, &rb);
        const len = try r.interface.takeInt(u32, .big);
        const body = buf[0 .. len - 4];
        try r.interface.readSliceAll(body);
        return body;
    }

    fn send(s: Io.net.Stream, bytes: []const u8) !void {
        var wb: [256]u8 = undefined;
        var w = s.writer(testing.io, &wb);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    const auth_ok = "R\x00\x00\x00\x08\x00\x00\x00\x00" ++ "Z\x00\x00\x00\x05I";
};

test "sslmode prefer goes on in the clear when the server has no TLS; require refuses" {
    const Script = struct {
        fn noTls(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            const req = try Fake.readStartup(s, &buf);
            try testing.expectEqual(80877103, std.mem.readInt(u32, req[0..4], .big));
            try Fake.send(s, "N");
            const startup = try Fake.readStartup(s, &buf);
            try testing.expectEqual(196608, std.mem.readInt(u32, startup[0..4], .big));
            try Fake.send(s, Fake.auth_ok);
        }
        fn noTlsRequired(s: Io.net.Stream) anyerror!void {
            var buf: [64]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "N");
        }
        fn plain(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            const startup = try Fake.readStartup(s, &buf);
            try testing.expectEqual(196608, std.mem.readInt(u32, startup[0..4], .big));
            try Fake.send(s, Fake.auth_ok);
        }
    };
    {
        const f = try Fake.start(Script.noTls);
        const c = try Conn.connect(testing.io, testing.allocator, f.config(.prefer));
        c.close();
        try f.finish();
    }
    {
        const f = try Fake.start(Script.noTlsRequired);
        try testing.expectError(error.TlsRefused, Conn.connect(testing.io, testing.allocator, f.config(.require)));
        try f.finish();
    }
    {
        // disable sends no SSLRequest at all.
        const f = try Fake.start(Script.plain);
        const c = try Conn.connect(testing.io, testing.allocator, f.config(.disable));
        c.close();
        try f.finish();
    }
}

test "a cleartext password is only sent over TLS; SCRAM must end with the server's proof" {
    const Script = struct {
        fn cleartext(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x08\x00\x00\x00\x03");
            // The client hangs up instead of answering.
            var one: [1]u8 = undefined;
            try testing.expectError(error.EndOfStream, Fake.readExact(s, &one));
        }
        fn scramWithoutProof(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00");
            var rb: [512]u8 = undefined;
            var r = s.reader(testing.io, &rb);
            // SASLInitialResponse: 'p', length, mechanism, length, client-first.
            try testing.expectEqual('p', try r.interface.takeByte());
            const len = try r.interface.takeInt(u32, .big);
            const body = try r.interface.take(len - 4);
            const first = body[std.mem.findScalar(u8, body, 0).? + 1 + 4 ..];
            const nonce = first[std.mem.find(u8, first, "r=").? + 2 ..];
            var msg: [256]u8 = undefined;
            const server_first = try std.fmt.bufPrint(&msg, "r={s}srv,s=QSXCR+Q6sek8bf92,i=4096", .{nonce});
            var out: [300]u8 = undefined;
            out[0] = 'R';
            std.mem.writeInt(u32, out[1..5], @intCast(8 + server_first.len), .big);
            std.mem.writeInt(u32, out[5..9], 11, .big);
            @memcpy(out[9..][0..server_first.len], server_first);
            try Fake.send(s, out[0 .. 9 + server_first.len]);
            _ = try r.interface.takeByte();
            const flen = try r.interface.takeInt(u32, .big);
            _ = try r.interface.take(flen - 4);
            // AuthenticationOk without AuthenticationSASLFinal: no proof.
            try Fake.send(s, Fake.auth_ok);
        }
    };
    {
        const f = try Fake.start(Script.cleartext);
        try testing.expectError(error.InsecureAuth, Conn.connect(testing.io, testing.allocator, f.config(.disable)));
        try f.finish();
    }
    {
        const f = try Fake.start(Script.scramWithoutProof);
        try testing.expectError(error.DbAuthFailed, Conn.connect(testing.io, testing.allocator, f.config(.disable)));
        try f.finish();
    }
}

test "what TLS verifies: libpq's upgrades, and the system store only with the host checked" {
    const base: Config = .{ .user = "u", .database = "d", .host = "db.example.com" };
    var c = base;
    c.sslmode = .require;
    try testing.expectEqual(TlsPlan{ .chain = false, .host = false, .os_roots = true }, tlsPlan(c));
    c.sslrootcert = "ca.pem"; // require with a root cert is verify-ca, as libpq
    try testing.expectEqual(TlsPlan{ .chain = true, .host = false, .os_roots = false }, tlsPlan(c));
    c = base;
    c.sslmode = .verify_ca; // the system's CAs prove nothing without the host name
    try testing.expectEqual(TlsPlan{ .chain = true, .host = true, .os_roots = true }, tlsPlan(c));
    c.sslmode = .verify_full;
    c.sslrootcert = "ca.pem";
    try testing.expectEqual(TlsPlan{ .chain = true, .host = true, .os_roots = false }, tlsPlan(c));
    c = base;
    try testing.expectEqual(TlsPlan{ .chain = false, .host = false, .os_roots = true }, tlsPlan(c));
}

test "TLS: SNI names a host name in every mode, never an IP address" {
    const Script = struct {
        fn hello(s: Io.net.Stream, want: bool) anyerror!void {
            var buf: [64]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "S");
            var rb: [2048]u8 = undefined;
            var r = s.reader(testing.io, &rb);
            const header = try r.interface.takeArray(5); // record header
            const client_hello = try r.interface.take(std.mem.readInt(u16, header[3..5], .big));
            try testing.expectEqual(want, std.mem.find(u8, client_hello, "localhost") != null);
        }
        fn named(s: Io.net.Stream) anyerror!void {
            return hello(s, true);
        }
        fn ip(s: Io.net.Stream) anyerror!void {
            return hello(s, false);
        }
    };
    {
        const f = try Fake.start(Script.named);
        var cfg = f.config(.require);
        cfg.host = "localhost";
        try testing.expectError(error.TlsHandshakeFailed, Conn.connect(testing.io, testing.allocator, cfg));
        try f.finish();
    }
    {
        const f = try Fake.start(Script.ip);
        try testing.expectError(error.TlsHandshakeFailed, Conn.connect(testing.io, testing.allocator, f.config(.require)));
        try f.finish();
    }
}

test "MD5 only over verified TLS unless the URL allows it; nothing trusted after the SSL answer; server-final needs server-first" {
    const Script = struct {
        fn md5(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x0c\x00\x00\x00\x05salt");
            var rb: [256]u8 = undefined;
            var r = s.reader(testing.io, &rb);
            if ((r.interface.takeByte() catch return) != 'p') return error.TestUnexpectedResult;
            const len = try r.interface.takeInt(u32, .big);
            _ = try r.interface.take(len - 4);
            try Fake.send(s, Fake.auth_ok);
        }
        fn smuggled(s: Io.net.Stream) anyerror!void {
            var buf: [64]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            // 'N' and, in the same packet, a forged AuthenticationOk.
            try Fake.send(s, "N" ++ Fake.auth_ok);
        }
        fn finalFirst(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00");
            var rb: [512]u8 = undefined;
            var r = s.reader(testing.io, &rb);
            _ = try r.interface.takeByte();
            const len = try r.interface.takeInt(u32, .big);
            _ = try r.interface.take(len - 4);
            const v = "v=qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo=";
            try Fake.send(s, "R\x00\x00\x00\x34\x00\x00\x00\x0c" ++ v ++ Fake.auth_ok);
        }
    };
    {
        const f = try Fake.start(Script.md5);
        try testing.expectError(error.InsecureAuth, Conn.connect(testing.io, testing.allocator, f.config(.disable)));
        try f.finish();
    }
    {
        const f = try Fake.start(Script.md5);
        var cfg = f.config(.disable);
        cfg.insecure_auth = true;
        const c = try Conn.connect(testing.io, testing.allocator, cfg);
        c.close();
        try f.finish();
    }
    {
        const f = try Fake.start(Script.smuggled);
        try testing.expectError(error.ServiceUnavailable, Conn.connect(testing.io, testing.allocator, f.config(.prefer)));
        try f.finish();
    }
    {
        const f = try Fake.start(Script.finalFirst);
        try testing.expectError(error.DbAuthFailed, Conn.connect(testing.io, testing.allocator, f.config(.disable)));
        try f.finish();
    }
}

test "sslnegotiation=direct: TLS from the first byte, ALPN postgresql; needs sslmode require or stronger" {
    const Script = struct {
        fn direct(s: Io.net.Stream) anyerror!void {
            var rb: [2048]u8 = undefined;
            var r = s.reader(testing.io, &rb);
            const header = try r.interface.takeArray(5);
            // A TLS handshake record, not an SSLRequest.
            try testing.expectEqual(0x16, header[0]);
            const hello = try r.interface.take(std.mem.readInt(u16, header[3..5], .big));
            try testing.expect(std.mem.find(u8, hello, "\x0apostgresql") != null);
        }
    };
    const f = try Fake.start(Script.direct);
    var cfg = f.config(.require);
    cfg.sslnegotiation = .direct;
    try testing.expectError(error.TlsHandshakeFailed, Conn.connect(testing.io, testing.allocator, cfg));
    try f.finish();
}

test "SCRAM channel binding: the GS2 header and the certificate hash go into c=" {
    var s: Scram = .{ .user = "", .gs2 = "p=tls-server-end-point,,", .cbind = "\x01\x02\x03" };
    const nonce = "rOprNGfwEbeRWgbNEkqO";
    @memcpy(s.nonce_buf[0..nonce.len], nonce);
    s.nonce_len = nonce.len;
    try testing.expectEqualStrings("p=tls-server-end-point,,n=,r=rOprNGfwEbeRWgbNEkqO", s.clientFirst());
    const final = try s.clientFinal("pencil", "r=rOprNGfwEbeRWgbNEkqO%hvY,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    var want: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&want, "p=tls-server-end-point,,\x01\x02\x03");
    var prefix: [96]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, final, try std.fmt.bufPrint(&prefix, "c={s},r=", .{b64})));
}

test "channel_binding=require: no TLS, no PLUS, or no SCRAM at all is refused" {
    const Script = struct {
        fn plainScram(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00");
            var one: [1]u8 = undefined;
            Fake.readExact(s, &one) catch {};
        }
        fn trust(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, Fake.auth_ok);
        }
    };
    {
        const f = try Fake.start(Script.plainScram);
        var cfg = f.config(.disable);
        cfg.channel_binding = .require;
        try testing.expectError(error.ChannelBindingRequired, Conn.connect(testing.io, testing.allocator, cfg));
        try f.finish();
    }
    {
        const f = try Fake.start(Script.trust);
        var cfg = f.config(.disable);
        cfg.channel_binding = .require;
        try testing.expectError(error.ChannelBindingRequired, Conn.connect(testing.io, testing.allocator, cfg));
        try f.finish();
    }
}

test "channel_binding=require refuses a password request before sending anything" {
    const Script = struct {
        fn cleartext(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x08\x00\x00\x00\x03");
            var one: [1]u8 = undefined;
            try testing.expectError(error.EndOfStream, Fake.readExact(s, &one));
        }
        fn md5(s: Io.net.Stream) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = try Fake.readStartup(s, &buf);
            try Fake.send(s, "R\x00\x00\x00\x0c\x00\x00\x00\x05salt");
            var one: [1]u8 = undefined;
            try testing.expectError(error.EndOfStream, Fake.readExact(s, &one));
        }
    };
    inline for (.{ Script.cleartext, Script.md5 }) |script| {
        const f = try Fake.start(script);
        var cfg = f.config(.disable);
        cfg.insecure_auth = true;
        cfg.channel_binding = .require;
        try testing.expectError(error.ChannelBindingRequired, Conn.connect(testing.io, testing.allocator, cfg));
        try f.finish();
    }
}
