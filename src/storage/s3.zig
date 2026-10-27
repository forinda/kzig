//! The S3 driver (AWS S3, MinIO, Cloudflare R2): requests signed with
//! SigV4, presigned GET links, ListObjectsV2. KickJS's `s3Storage`, without
//! multipart uploads, upload forms, compose or credential providers.
const std = @import("std");
const builtin = @import("builtin");
const store = @import("../storage.zig");
const cron = @import("../cron.zig");
const kzig_config = @import("../config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const max_expires = 7 * 24 * 60 * 60;

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
};

/// `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`,
/// `S3_SECRET_ACCESS_KEY`, `S3_SESSION_TOKEN`, `S3_FORCE_PATH_STYLE` (KickJS
/// `S3Settings`). Optional here so an app on disk storage boots without
/// them; `S3.fromSettings` names what is missing.
pub const Settings = struct {
    pub const prefix = "S3";
    bucket: ?[]const u8 = null,
    region: []const u8 = "us-east-1",
    /// `http://localhost:9000` for MinIO; AWS's regional endpoint when unset.
    endpoint: ?[]const u8 = null,
    access_key_id: ?[]const u8 = null,
    secret_access_key: ?[]const u8 = null,
    session_token: ?[]const u8 = null,
    /// `bucket` in the path rather than the host; on by default with an endpoint.
    force_path_style: ?bool = null,

    pub fn validate(self: *const Settings, issues: *@import("../decode.zig").Issues) !void {
        if ((self.access_key_id == null) != (self.secret_access_key == null))
            try issues.add(if (self.access_key_id == null) "access_key_id" else "secret_access_key", "required with the other key");
        if (self.endpoint) |e| _ = std.Uri.parse(e) catch try issues.add("endpoint", "must be a URL");
    }
};

pub const SignInput = struct {
    method: []const u8,
    /// As sent: `host` or `host:port`.
    host: []const u8,
    /// URI-encoded.
    path: []const u8,
    /// Not encoded.
    query: []const [2][]const u8 = &.{},
    /// Lower-case names besides `host`, not encoded.
    headers: []const [2][]const u8 = &.{},
    payload_hash: []const u8 = "UNSIGNED-PAYLOAD",
    region: []const u8,
    credentials: Credentials,
    /// Unix seconds.
    time: i64,
};

pub const Signed = struct {
    signature: [64]u8,
    credential: []const u8,
    signed_headers: []const u8,
};

/// AWS Signature Version 4 for S3.
pub fn sign(a: Allocator, in: SignInput) !Signed {
    var stamp_buf: [16]u8 = undefined;
    const stamp = amzDate(&stamp_buf, in.time);
    const scope = try std.mem.concat(a, u8, &.{ stamp[0..8], "/", in.region, "/s3/aws4_request" });

    const headers = try a.alloc([2][]const u8, in.headers.len + 1);
    headers[0] = .{ "host", in.host };
    for (in.headers, headers[1..]) |h, *o| o.* = .{ h[0], std.mem.trim(u8, h[1], " \t") };
    std.mem.sort([2][]const u8, headers, {}, pairLess);

    var canonical: std.Io.Writer.Allocating = .init(a);
    const w = &canonical.writer;
    try w.print("{s}\n{s}\n{s}\n", .{ in.method, in.path, try canonicalQuery(a, in.query) });
    for (headers) |h| try w.print("{s}:{s}\n", .{ h[0], h[1] });
    var names: std.ArrayList(u8) = .empty;
    for (headers, 0..) |h, i| {
        if (i > 0) try names.append(a, ';');
        try names.appendSlice(a, h[0]);
    }
    try w.print("\n{s}\n{s}", .{ names.items, in.payload_hash });

    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ stamp, scope, &hexSha256(canonical.written()) });
    var key: [HmacSha256.mac_length]u8 = undefined;
    const secret = try std.mem.concat(a, u8, &.{ "AWS4", in.credentials.secret_access_key });
    HmacSha256.create(&key, stamp[0..8], secret);
    for ([_][]const u8{ in.region, "s3", "aws4_request" }) |part| HmacSha256.create(&key, part, &key);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, to_sign, &key);
    return .{
        .signature = std.fmt.bytesToHex(mac, .lower),
        .credential = try std.mem.concat(a, u8, &.{ in.credentials.access_key_id, "/", scope }),
        .signed_headers = names.items,
    };
}

/// A presigned URL's query string (no `?`): the `X-Amz-*` parameters,
/// `in.query`, and the signature last.
pub fn presignQuery(a: Allocator, in: SignInput, expires_in: u32) ![]const u8 {
    var stamp_buf: [16]u8 = undefined;
    const stamp = amzDate(&stamp_buf, in.time);
    var query: std.ArrayList([2][]const u8) = .empty;
    try query.appendSlice(a, in.query);
    try query.appendSlice(a, &.{
        .{ "X-Amz-Algorithm", "AWS4-HMAC-SHA256" },
        .{ "X-Amz-Credential", try std.mem.concat(a, u8, &.{ in.credentials.access_key_id, "/", stamp[0..8], "/", in.region, "/s3/aws4_request" }) },
        .{ "X-Amz-Date", try a.dupe(u8, stamp) },
        .{ "X-Amz-Expires", try std.fmt.allocPrint(a, "{d}", .{expires_in}) },
        .{ "X-Amz-SignedHeaders", "host" },
    });
    if (in.credentials.session_token) |t| try query.append(a, .{ "X-Amz-Security-Token", t });
    var signing = in;
    signing.query = query.items;
    signing.headers = &.{};
    signing.payload_hash = "UNSIGNED-PAYLOAD";
    const signed = try sign(a, signing);
    return std.mem.concat(a, u8, &.{ try canonicalQuery(a, query.items), "&X-Amz-Signature=", &signed.signature });
}

fn canonicalQuery(a: Allocator, query: []const [2][]const u8) ![]const u8 {
    const encoded = try a.alloc([2][]const u8, query.len);
    for (query, encoded) |q, *e| e.* = .{ try uriEncode(a, q[0], true), try uriEncode(a, q[1], true) };
    std.mem.sort([2][]const u8, encoded, {}, pairLess);
    var out: std.ArrayList(u8) = .empty;
    for (encoded, 0..) |q, i| {
        if (i > 0) try out.append(a, '&');
        try out.print(a, "{s}={s}", .{ q[0], q[1] });
    }
    return out.items;
}

fn pairLess(_: void, x: [2][]const u8, y: [2][]const u8) bool {
    return switch (std.mem.order(u8, x[0], y[0])) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, x[1], y[1]) == .lt,
    };
}

/// AWS's URI encoding: everything but `A-Za-z0-9-_.~` as `%XX`; `/` kept
/// unless `slash`.
pub fn uriEncode(a: Allocator, s: []const u8, slash: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or (c == '/' and !slash)) {
            try out.append(a, c);
        } else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

fn hexSha256(data: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// `20130524T000000Z`.
fn amzDate(buf: *[16]u8, t: i64) []const u8 {
    const days = @divFloor(t, 86400);
    const d = cron.fromCivil(days);
    const s: u64 = @intCast(t - days * 86400);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ @as(u32, @intCast(d.year)), d.month, d.day, s / 3600, s % 3600 / 60, s % 60 }) catch unreachable;
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

/// `Fri, 24 May 2013 00:00:00 GMT` (RFC 9110 IMF-fixdate).
pub fn httpDate(buf: *[29]u8, t: i64) []const u8 {
    const days = @divFloor(t, 86400);
    const d = cron.fromCivil(days);
    const s: u64 = @intCast(t - days * 86400);
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ weekdays[@intCast(@mod(days, 7))], d.day, months[d.month - 1], @as(u32, @intCast(d.year)), s / 3600, s % 3600 / 60, s % 60 }) catch unreachable;
}

pub fn parseHttpDate(s: []const u8) ?i64 {
    // `Fri, 24 May 2013 00:00:00 GMT`
    if (s.len != 29) return null;
    const month = for (months, 1..) |m, i| {
        if (std.mem.eql(u8, s[8..11], m)) break i;
    } else return null;
    return civilTime(s[12..16], month, s[5..7], s[17..19], s[20..22], s[23..25]);
}

/// `2013-05-24T00:00:00.000Z`.
fn parseIso(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    return civilTime(s[0..4], month, s[8..10], s[11..13], s[14..16], s[17..19]);
}

fn civilTime(y: []const u8, month: usize, d: []const u8, h: []const u8, mi: []const u8, sec: []const u8) ?i64 {
    const year = std.fmt.parseInt(i32, y, 10) catch return null;
    const day = std.fmt.parseInt(u8, d, 10) catch return null;
    const hh = std.fmt.parseInt(i64, h, 10) catch return null;
    const mm = std.fmt.parseInt(i64, mi, 10) catch return null;
    const ss = std.fmt.parseInt(i64, sec, 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return cron.civil(year, @intCast(month), day) * 86400 + hh * 3600 + mm * 60 + ss;
}

/// `<name>…</name>` occurrences in `xml`, from `from`.
fn tagAt(xml: []const u8, from: usize, comptime name: []const u8) ?struct { body: []const u8, end: usize } {
    const open = std.mem.findPos(u8, xml, from, "<" ++ name ++ ">") orelse return null;
    const start = open + name.len + 2;
    const close = std.mem.findPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return .{ .body = xml[start..close], .end = close + name.len + 3 };
}

fn tag(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    return if (tagAt(xml, 0, name)) |t| t.body else null;
}

fn xmlUnescape(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, s, '&') == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.findScalarPos(u8, s, i, ';')) |semi| {
            const entity = s[i + 1 .. semi];
            const c: ?u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (entity.len > 1 and entity[0] == '#')
                (if (entity[1] == 'x') std.fmt.parseInt(u21, entity[2..], 16) catch null else std.fmt.parseInt(u21, entity[1..], 10) catch null)
            else
                null;
            if (c) |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidXml;
                try out.appendSlice(a, buf[0..n]);
                i = semi + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// A ListObjectsV2 answer.
pub fn parseList(a: Allocator, xml: []const u8) !store.ListPage {
    var files: std.ArrayList(store.FileInfo) = .empty;
    var at: usize = 0;
    while (tagAt(xml, at, "Contents")) |entry| : (at = entry.end) {
        try files.append(a, .{
            .key = try xmlUnescape(a, tag(entry.body, "Key") orelse return error.InvalidXml),
            .size = std.fmt.parseInt(u64, tag(entry.body, "Size") orelse "0", 10) catch return error.InvalidXml,
            .last_modified = parseIso(tag(entry.body, "LastModified") orelse "") orelse 0,
        });
    }
    const truncated = std.mem.eql(u8, tag(xml, "IsTruncated") orelse "false", "true");
    return .{
        .files = files.items,
        .cursor = if (truncated) if (tag(xml, "NextContinuationToken")) |t| try xmlUnescape(a, t) else null else null,
    };
}

pub const Options = struct {
    bucket: []const u8,
    region: []const u8 = "us-east-1",
    endpoint: ?[]const u8 = null,
    credentials: Credentials,
    force_path_style: ?bool = null,
};

/// A bucket as a `Storage` (KickJS `s3Storage`).
pub const S3 = struct {
    io: Io,
    gpa: Allocator,
    client: std.http.Client,
    region: []const u8,
    credentials: Credentials,
    /// `https` or `http`, then the authority the requests go to.
    scheme: []const u8,
    host: []const u8,
    /// `/bucket` (path style) or empty (the bucket is in `host`).
    base_path: []const u8,
    bucket: []const u8,
    /// Owns the strings above.
    arena: std.heap.ArenaAllocator,

    pub fn init(io: Io, gpa: Allocator, o: Options) !S3 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const endpoint = o.endpoint orelse try std.fmt.allocPrint(a, "https://s3.{s}.amazonaws.com", .{o.region});
        const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = (std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.InvalidEndpoint).bytes;
        const authority = if (uri.port) |p| try std.fmt.allocPrint(a, "{s}:{d}", .{ host, p }) else try a.dupe(u8, host);
        const path_style = o.force_path_style orelse (o.endpoint != null);
        const prefix = std.mem.trimEnd(u8, uri.path.percent_encoded, "/");
        return .{
            .io = io,
            .gpa = gpa,
            .client = .{ .allocator = gpa, .io = io },
            .region = try a.dupe(u8, o.region),
            .credentials = .{
                .access_key_id = try a.dupe(u8, o.credentials.access_key_id),
                .secret_access_key = try a.dupe(u8, o.credentials.secret_access_key),
                .session_token = if (o.credentials.session_token) |t| try a.dupe(u8, t) else null,
            },
            .scheme = try a.dupe(u8, uri.scheme),
            .host = if (path_style) authority else try std.mem.concat(a, u8, &.{ o.bucket, ".", authority }),
            .base_path = if (path_style) try std.mem.concat(a, u8, &.{ prefix, "/", try uriEncode(a, o.bucket, true) }) else try a.dupe(u8, prefix),
            .bucket = try a.dupe(u8, o.bucket),
            .arena = arena,
        };
    }

    /// From `S3_*` (`kzig.storage.S3Settings`); `error.MissingS3Settings`,
    /// logged with the variable's name, when one is unset.
    pub fn fromSettings(io: Io, gpa: Allocator, s: *const Settings) !S3 {
        const bucket = s.bucket orelse return missing("S3_BUCKET");
        const id = s.access_key_id orelse return missing("S3_ACCESS_KEY_ID");
        return init(io, gpa, .{
            .bucket = bucket,
            .region = s.region,
            .endpoint = s.endpoint,
            .credentials = .{ .access_key_id = id, .secret_access_key = s.secret_access_key.?, .session_token = s.session_token },
            .force_path_style = s.force_path_style,
        });
    }

    fn missing(comptime name: []const u8) error{MissingS3Settings} {
        if (!builtin.is_test) std.log.err("S3 storage: {s} is required", .{name});
        return error.MissingS3Settings;
    }

    pub fn deinit(s: *S3) void {
        s.client.deinit();
        s.arena.deinit();
    }

    pub fn storage(s: *S3) store.Storage {
        return .{ .ptr = s, .vtable = &vtable };
    }

    const vtable: store.Storage.VTable = .{ .put = put, .get = get, .stat = stat, .delete = delete, .list = list, .url = url };

    const Reply = struct {
        status: std.http.Status,
        body: []const u8 = "",
        content_type: ?[]const u8 = null,
        content_length: ?u64 = null,
        last_modified: ?i64 = null,
    };

    fn nowS(s: *S3) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(s.io).toNanoseconds(), std.time.ns_per_s));
    }

    fn pathOf(s: *S3, a: Allocator, key: ?[]const u8) ![]const u8 {
        return if (key) |k| std.mem.concat(a, u8, &.{ s.base_path, "/", try uriEncode(a, k, false) }) else std.mem.concat(a, u8, &.{ s.base_path, "/" });
    }

    // ponytail: no timeout; a stalled bucket holds the request. A deadline
    // around the client's read (as the runtimes' watchdog) if that bites.
    /// A signed request; the reply's strings live in `a`.
    fn send(s: *S3, a: Allocator, method: std.http.Method, key: ?[]const u8, query: []const [2][]const u8, body: ?[]const u8, content_type: ?[]const u8) !Reply {
        const path = try s.pathOf(a, key);
        const payload_hash = if (body) |b| try a.dupe(u8, &hexSha256(b)) else empty_hash;
        var stamp_buf: [16]u8 = undefined;
        const stamp = amzDate(&stamp_buf, s.nowS());
        var amz: std.ArrayList([2][]const u8) = .empty;
        try amz.appendSlice(a, &.{ .{ "x-amz-content-sha256", payload_hash }, .{ "x-amz-date", try a.dupe(u8, stamp) } });
        if (s.credentials.session_token) |t| try amz.append(a, .{ "x-amz-security-token", t });
        const signed = try sign(a, .{
            .method = @tagName(method),
            .host = s.host,
            .path = path,
            .query = query,
            .headers = amz.items,
            .payload_hash = payload_hash,
            .region = s.region,
            .credentials = s.credentials,
            .time = s.nowS(),
        });
        var headers: std.ArrayList(std.http.Header) = .empty;
        for (amz.items) |h| try headers.append(a, .{ .name = h[0], .value = h[1] });
        try headers.append(a, .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}, SignedHeaders={s}, Signature={s}", .{ signed.credential, signed.signed_headers, &signed.signature }) });

        const qs = try canonicalQuery(a, query);
        const target = try std.fmt.allocPrint(a, "{s}://{s}{s}{s}{s}", .{ s.scheme, s.host, path, if (qs.len > 0) "?" else "", qs });
        const uri = try std.Uri.parse(target);
        var req = try s.client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
                .accept_encoding = .omit,
            },
            .extra_headers = headers.items,
        });
        defer req.deinit();
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            try req.sendBodyComplete(@constCast(b));
        } else try req.sendBodiless();
        var redirect: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect);
        var reply: Reply = .{
            .status = response.head.status,
            .content_type = if (response.head.content_type) |ct| try a.dupe(u8, ct) else null,
            .content_length = response.head.content_length,
        };
        var it = response.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "last-modified")) {
            reply.last_modified = parseHttpDate(h.value);
        };
        // No body after HEAD, 204 or 304 (RFC 9110 §6.4.1), whatever the
        // framing headers say. std's client would wait for one (until the
        // connection closes) on a 204 without Content-Length, as SeaweedFS
        // answers a DELETE: mark it read, which also keeps the connection.
        if (reply.status == .no_content or reply.status == .not_modified) {
            req.reader.state = .ready;
        } else if (method != .HEAD) {
            var transfer: [8192]u8 = undefined;
            reply.body = try response.reader(&transfer).allocRemaining(a, .unlimited);
        }
        return reply;
    }

    /// A non-2xx answer, logged with S3's message.
    fn failed(method: std.http.Method, key: ?[]const u8, reply: Reply) error{S3RequestFailed} {
        if (!builtin.is_test) std.log.err("S3 {t} {s}: {d} {s}", .{ method, key orelse "(bucket)", @backingInt(reply.status), reply.body[0..@min(reply.body.len, 300)] });
        return error.S3RequestFailed;
    }

    fn ok(status: std.http.Status) bool {
        return @backingInt(status) >= 200 and @backingInt(status) < 300;
    }

    fn put(ptr: *anyopaque, key: []const u8, data: []const u8, options: store.PutOptions) anyerror!void {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const reply = try s.send(arena.allocator(), .PUT, key, &.{}, data, options.content_type);
        if (!ok(reply.status)) return failed(.PUT, key, reply);
    }

    fn get(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?[]u8 {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const reply = try s.send(arena.allocator(), .GET, key, &.{}, null, null);
        if (reply.status == .not_found) return null;
        if (!ok(reply.status)) return failed(.GET, key, reply);
        return try a.dupe(u8, reply.body);
    }

    fn stat(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?store.FileInfo {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const reply = try s.send(arena.allocator(), .HEAD, key, &.{}, null, null);
        if (reply.status == .not_found) return null;
        if (!ok(reply.status)) return failed(.HEAD, key, reply);
        return .{
            .key = try a.dupe(u8, key),
            .size = reply.content_length orelse 0,
            .last_modified = reply.last_modified orelse 0,
            .content_type = if (reply.content_type) |ct| try a.dupe(u8, ct) else null,
        };
    }

    fn delete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const reply = try s.send(arena.allocator(), .DELETE, key, &.{}, null, null);
        if (!ok(reply.status) and reply.status != .not_found) return failed(.DELETE, key, reply);
    }

    /// The cursor is S3's continuation token.
    fn list(ptr: *anyopaque, a: Allocator, options: store.ListOptions) anyerror!store.ListPage {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        var query: std.ArrayList([2][]const u8) = .empty;
        try query.appendSlice(arena.allocator(), &.{ .{ "list-type", "2" }, .{ "max-keys", try std.fmt.allocPrint(arena.allocator(), "{d}", .{options.limit}) } });
        if (options.prefix.len > 0) try query.append(arena.allocator(), .{ "prefix", options.prefix });
        if (options.cursor) |c| try query.append(arena.allocator(), .{ "continuation-token", c });
        const reply = try s.send(arena.allocator(), .GET, null, query.items, null, null);
        if (!ok(reply.status)) return failed(.GET, null, reply);
        return parseList(a, reply.body);
    }

    /// A presigned GET, valid `expires_in` seconds (the bucket enforces it).
    fn url(ptr: *anyopaque, a: Allocator, key: []const u8, options: store.UrlOptions) anyerror![]const u8 {
        const s: *S3 = @ptrCast(@alignCast(ptr));
        if (options.expires_in < 1 or options.expires_in > max_expires) return error.InvalidExpiry;
        const path = try s.pathOf(a, key);
        const query = try presignQuery(a, .{ .method = "GET", .host = s.host, .path = path, .region = s.region, .credentials = s.credentials, .time = s.nowS() }, options.expires_in);
        return std.fmt.allocPrint(a, "{s}://{s}{s}?{s}", .{ s.scheme, s.host, path, query });
    }
};

const testing = std.testing;

// AWS's documented examples (S3 API reference, "Signature Calculations"):
// examplebucket, 2013-05-24, us-east-1.
const example: Credentials = .{
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};
const example_time: i64 = 1369353600; // 20130524T000000Z

test "sign: AWS's GET Object example (Range header)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const signed = try sign(arena.allocator(), .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .headers = &.{
            .{ "range", "bytes=0-9" },
            .{ "x-amz-content-sha256", empty_hash },
            .{ "x-amz-date", "20130524T000000Z" },
        },
        .payload_hash = empty_hash,
        .region = "us-east-1",
        .credentials = example,
        .time = example_time,
    });
    try testing.expectEqualStrings("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", &signed.signature);
    try testing.expectEqualStrings("host;range;x-amz-content-sha256;x-amz-date", signed.signed_headers);
}

test "presign: AWS's presigned GET example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const query = try presignQuery(arena.allocator(), .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .region = "us-east-1",
        .credentials = example,
        .time = example_time,
    }, 86400);
    try testing.expect(std.mem.endsWith(u8, query, "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"));
    try testing.expect(std.mem.startsWith(u8, query, "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&"));
}

test "uri encoding: AWS's rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a%20b%2Fc~d_e-f.g", try uriEncode(arena.allocator(), "a b/c~d_e-f.g", true));
    try testing.expectEqualStrings("files/a%20b.png", try uriEncode(arena.allocator(), "files/a b.png", false));
}

test "list XML and HTTP dates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult><Name>b</Name><Prefix>files/</Prefix><IsTruncated>true</IsTruncated>
        \\<Contents><Key>files/a&amp;b.png</Key><LastModified>2013-05-24T00:00:00.000Z</LastModified><Size>11</Size></Contents>
        \\<Contents><Key>files/c</Key><LastModified>2013-05-24T00:00:01.000Z</LastModified><Size>0</Size></Contents>
        \\<NextContinuationToken>tok/en</NextContinuationToken></ListBucketResult>
    ;
    const page = try parseList(arena.allocator(), xml);
    try testing.expectEqual(2, page.files.len);
    try testing.expectEqualStrings("files/a&b.png", page.files[0].key);
    try testing.expectEqual(11, page.files[0].size);
    try testing.expectEqual(example_time, page.files[0].last_modified);
    try testing.expectEqualStrings("tok/en", page.cursor.?);
    try testing.expectEqual(example_time, parseHttpDate("Fri, 24 May 2013 00:00:00 GMT").?);
    var buf: [29]u8 = undefined;
    try testing.expectEqualStrings("Fri, 24 May 2013 00:00:00 GMT", httpDate(&buf, example_time));
}

const app_mod = @import("../app.zig");
const Ctx = @import("../context.zig").Ctx;
const percentDecode = @import("../context.zig").percentDecode;

/// A bucket that checks every request's signature (header or presigned)
/// the way S3 does, backed by the memory driver.
const FakeS3 = struct {
    process: *const app_mod.Process,
    mem: store.Memory = undefined,

    pub const routes = .{
        .{ .method = .GET, .path = "/:bucket", .handler = "listObjects" },
        .{ .method = .GET, .path = "/:bucket/*", .handler = "getObject" },
        .{ .method = .PUT, .path = "/:bucket/*", .handler = "putObject" },
        .{ .method = .DELETE, .path = "/:bucket/*", .handler = "deleteObject" },
    };

    pub fn init(self: *FakeS3) void {
        self.mem = .init(self.process.io, self.process.gpa);
    }

    pub fn deinit(self: *FakeS3) void {
        self.mem.deinit();
    }

    fn query(ctx: *Ctx) ![]const [2][]const u8 {
        var out: std.ArrayList([2][]const u8) = .empty;
        var it = std.mem.splitScalar(u8, ctx.req.query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.findScalar(u8, pair, '=') orelse pair.len;
            try out.append(ctx.arena, .{ try percentDecode(ctx.arena, pair[0..eq], false), try percentDecode(ctx.arena, if (eq < pair.len) pair[eq + 1 ..] else "", false) });
        }
        return out.items;
    }

    fn param(q: []const [2][]const u8, name: []const u8) ?[]const u8 {
        for (q) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }

    fn verify(ctx: *Ctx) !void {
        const q = try query(ctx);
        const host = ctx.header("host") orelse "";
        const path = ctx.req.path[0 .. std.mem.findScalar(u8, ctx.req.path, '?') orelse ctx.req.path.len];
        if (param(q, "X-Amz-Signature")) |given| {
            const date = param(q, "X-Amz-Date") orelse return deny(ctx);
            var t = civilTime(date[0..4], std.fmt.parseInt(u8, date[4..6], 10) catch 0, date[6..8], date[9..11], date[11..13], date[13..15]) orelse return deny(ctx);
            const expires = std.fmt.parseInt(u32, param(q, "X-Amz-Expires") orelse "0", 10) catch 0;
            const now: i64 = @intCast(@divFloor(Io.Clock.real.now(ctx.io.?).toNanoseconds(), std.time.ns_per_s));
            if (now > t + expires) return deny(ctx);
            var rest: std.ArrayList([2][]const u8) = .empty;
            for (q) |p| if (!std.mem.startsWith(u8, p[0], "X-Amz-")) try rest.append(ctx.arena, p);
            const want = try presignQuery(ctx.arena, .{ .method = "GET", .host = host, .path = path, .query = rest.items, .region = "us-east-1", .credentials = example, .time = t }, expires);
            t = 0;
            if (!std.mem.endsWith(u8, want, given)) return deny(ctx);
            return;
        }
        // AWS4-HMAC-SHA256 Credential=…, SignedHeaders=a;b, Signature=hex
        const auth = ctx.header("authorization") orelse return deny(ctx);
        const sh_at = std.mem.find(u8, auth, "SignedHeaders=") orelse return deny(ctx);
        const sh = auth[sh_at + "SignedHeaders=".len .. std.mem.findScalarPos(u8, auth, sh_at, ',') orelse return deny(ctx)];
        const given = auth[(std.mem.find(u8, auth, "Signature=") orelse return deny(ctx)) + "Signature=".len ..];
        var headers: std.ArrayList([2][]const u8) = .empty;
        var names = std.mem.splitScalar(u8, sh, ';');
        while (names.next()) |n| if (!std.mem.eql(u8, n, "host")) try headers.append(ctx.arena, .{ n, ctx.header(n) orelse return deny(ctx) });
        const payload = ctx.header("x-amz-content-sha256") orelse return deny(ctx);
        if (!std.mem.eql(u8, payload, &hexSha256(ctx.req.body))) return deny(ctx);
        const date = ctx.header("x-amz-date") orelse return deny(ctx);
        const t = civilTime(date[0..4], std.fmt.parseInt(u8, date[4..6], 10) catch 0, date[6..8], date[9..11], date[11..13], date[13..15]) orelse return deny(ctx);
        const want = try sign(ctx.arena, .{ .method = @tagName(ctx.req.method), .host = host, .path = path, .query = q, .headers = headers.items, .payload_hash = payload, .region = "us-east-1", .credentials = example, .time = t });
        if (!std.mem.eql(u8, &want.signature, given)) return deny(ctx);
    }

    fn deny(ctx: *Ctx) error{HttpProblem} {
        return ctx.fail(.forbidden, "SignatureDoesNotMatch");
    }

    pub fn getObject(self: *FakeS3, ctx: *Ctx) !void {
        try verify(ctx);
        const key = ctx.param("*").?;
        const info = try self.mem.storage().stat(ctx.arena, key) orelse return ctx.fail(.not_found, "NoSuchKey");
        const data = (try self.mem.storage().get(ctx.arena, key)).?;
        var buf: [29]u8 = undefined;
        try ctx.setHeader("last-modified", try ctx.arena.dupe(u8, httpDate(&buf, info.last_modified)));
        try ctx.bytes(info.content_type orelse "application/octet-stream", data);
    }

    pub fn putObject(self: *FakeS3, ctx: *Ctx) !void {
        try verify(ctx);
        try self.mem.storage().put(ctx.param("*").?, ctx.req.body, .{ .content_type = ctx.header("content-type") });
        ctx.status(.ok);
    }

    pub fn deleteObject(self: *FakeS3, ctx: *Ctx) !void {
        try verify(ctx);
        try self.mem.storage().delete(ctx.param("*").?);
    }

    pub fn listObjects(self: *FakeS3, ctx: *Ctx) !void {
        try verify(ctx);
        const q = try query(ctx);
        const limit = std.fmt.parseInt(u32, param(q, "max-keys") orelse "1000", 10) catch 1000;
        const page = try self.mem.storage().list(ctx.arena, .{ .prefix = param(q, "prefix") orelse "", .cursor = param(q, "continuation-token"), .limit = limit });
        var xml: std.ArrayList(u8) = .empty;
        try xml.print(ctx.arena, "<ListBucketResult><IsTruncated>{}</IsTruncated>", .{page.cursor != null});
        for (page.files) |f| {
            var buf: [16]u8 = undefined;
            const stamp = amzDate(&buf, f.last_modified);
            try xml.print(ctx.arena, "<Contents><Key>{s}</Key><LastModified>{s}-{s}-{s}T{s}:{s}:{s}.000Z</LastModified><Size>{d}</Size></Contents>", .{ f.key, stamp[0..4], stamp[4..6], stamp[6..8], stamp[9..11], stamp[11..13], stamp[13..15], f.size });
        }
        if (page.cursor) |c| try xml.print(ctx.arena, "<NextContinuationToken>{s}</NextContinuationToken>", .{c});
        try xml.appendSlice(ctx.arena, "</ListBucketResult>");
        try ctx.bytes("application/xml", xml.items);
    }
};

const FakeApp = app_mod.App(.{
    .modules = &.{app_mod.Module(.{ .name = "S3", .prefix = false, .version = false, .controllers = &.{FakeS3} })},
    .health = false,
});

const Fake = struct {
    app: FakeApp,
    srv: @import("../runtime/std.zig").Server(FakeApp),
    fut: Io.Future(anyerror!void),

    fn start(self: *Fake) !void {
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        try env.put("NODE_ENV", "test");
        try self.app.init(testing.io, testing.allocator, &env);
        self.srv = try .init(testing.io, testing.allocator, &self.app, .{ .port = 0 });
        self.fut = try testing.io.concurrent(run, .{&self.srv});
    }
    fn run(srv: *@import("../runtime/std.zig").Server(FakeApp)) anyerror!void {
        return srv.run();
    }
    fn stop(self: *Fake) void {
        self.srv.shutdown();
        self.fut.cancel(testing.io) catch {};
        self.srv.deinit();
        self.app.deinit();
    }
    fn endpoint(self: *Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.srv.port()}) catch unreachable;
    }
};

test "S3 keeps the contract, against a bucket that checks every signature" {
    var fake: Fake = undefined;
    try fake.start();
    defer fake.stop();
    var buf: [64]u8 = undefined;
    var s3: S3 = try .init(testing.io, testing.allocator, .{ .bucket = "test-bucket", .endpoint = fake.endpoint(&buf), .credentials = example });
    defer s3.deinit();
    try store.expectContract(s3.storage());

    // A presigned link works without credentials.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try s3.storage().put("shared/note.txt", "hi there", .{ .content_type = "text/plain" });
    const link = try s3.storage().url(arena.allocator(), "shared/note.txt", .{ .expires_in = 60 });
    var body: std.Io.Writer.Allocating = .init(arena.allocator());
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const res = try client.fetch(.{ .location = .{ .url = link }, .response_writer = &body.writer });
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqualStrings("hi there", body.written());
    try testing.expectError(error.InvalidExpiry, s3.storage().url(arena.allocator(), "shared/note.txt", .{ .expires_in = 604_801 }));

    // A wrong secret is refused.
    var bad: S3 = try .init(testing.io, testing.allocator, .{ .bucket = "test-bucket", .endpoint = fake.endpoint(&buf), .credentials = .{ .access_key_id = example.access_key_id, .secret_access_key = "nope" } });
    defer bad.deinit();
    try testing.expectError(error.S3RequestFailed, bad.storage().put("x", "y", .{}));
}

test "fromSettings names what is missing" {
    try testing.expectError(error.MissingS3Settings, S3.fromSettings(testing.io, testing.allocator, &.{}));
    try testing.expectError(error.MissingS3Settings, S3.fromSettings(testing.io, testing.allocator, &.{ .bucket = "b" }));
}

// Against a real bucket when `S3_TEST_ENDPOINT` is set (CI runs one):
// `S3_TEST_BUCKET` is a scratch bucket this test empties first.
test "S3 keeps the contract against a real bucket" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const endpoint = env.get("S3_TEST_ENDPOINT") orelse return error.SkipZigTest;
    var s3: S3 = try .init(testing.io, testing.allocator, .{
        .bucket = env.get("S3_TEST_BUCKET") orelse "kzig-test",
        .region = env.get("S3_TEST_REGION") orelse "us-east-1",
        .endpoint = endpoint,
        .credentials = .{
            .access_key_id = env.get("S3_TEST_ACCESS_KEY_ID") orelse "minioadmin",
            .secret_access_key = env.get("S3_TEST_SECRET_ACCESS_KEY") orelse "minioadmin",
        },
    });
    defer s3.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ((try s3.storage().list(a, .{})).files) |f| try s3.storage().delete(f.key);
    try store.expectContract(s3.storage());

    // The bucket itself checks the presigned link and its expiry.
    try s3.storage().put("shared/note.txt", "hi there", .{ .content_type = "text/plain" });
    const link = try s3.storage().url(a, "shared/note.txt", .{ .expires_in = 60 });
    var body: std.Io.Writer.Allocating = .init(a);
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const res = try client.fetch(.{ .location = .{ .url = link }, .response_writer = &body.writer });
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqualStrings("hi there", body.written());
    const info = (try s3.storage().stat(a, "shared/note.txt")).?;
    try testing.expectEqualStrings("text/plain", info.content_type.?);
}

fn bare204(server: *Io.net.Server) !void {
    const conn = try server.accept(testing.io);
    defer conn.close(testing.io);
    var buf: [4096]u8 = undefined;
    var r = conn.reader(testing.io, &buf);
    while (true) {
        const line = try r.interface.takeDelimiterInclusive('\n');
        if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
    }
    var wbuf: [128]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    try w.interface.writeAll("HTTP/1.1 204 No Content\r\nserver: bare\r\n\r\n");
    try w.interface.flush();
    // Keep-alive: the connection stays open.
    try testing.io.sleep(.fromSeconds(2), .awake);
}

test "a 204 without Content-Length doesn't wait for the connection to close" {
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var fut = try testing.io.concurrent(bare204, .{&server});
    defer _ = fut.await(testing.io) catch {};
    var buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var s3: S3 = try .init(testing.io, testing.allocator, .{ .bucket = "b", .endpoint = endpoint, .credentials = example });
    defer s3.deinit();
    const t0 = Io.Clock.awake.now(testing.io);
    try s3.storage().delete("gone");
    try testing.expect(t0.durationTo(Io.Clock.awake.now(testing.io)).toNanoseconds() < std.time.ns_per_s);
}
