//! KickJS's `@FileUpload`: `multipart/form-data` read from the buffered body
//! as `got: struct { upload: kzig.Upload(.{ … }) }`. The runtime's
//! `max_body_bytes` still bounds the whole request.
const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const kzig_testing = @import("../core/testing.zig");

const Allocator = std.mem.Allocator;

pub const File = struct {
    /// The form field it came in.
    field: []const u8,
    /// The client's name, safe to show: no directory, no control characters.
    /// Still the client's choice — store under `filename`.
    original_name: []const u8,
    /// A random UUID, plus the client's extension when it names the file's type.
    filename: []const u8,
    content_type: []const u8,
    data: []const u8,
};

pub const Field = struct { name: []const u8, value: []const u8 };

pub const Config = struct {
    field: []const u8 = "file",
    /// Per file; over it is 413 (KickJS's default, 5 MiB).
    max_size: usize = 5 * 1024 * 1024,
    /// Files on `field`; more is 413.
    max_count: u32 = 1,
    /// Extensions (`"png"`), MIME types or wildcards (`"image/*"`); a type
    /// outside them is 415. Empty takes any type.
    allowed_types: []const []const u8 = &.{},
};

/// Text fields and parts in all a request may carry (KickJS: 1000 fields).
const max_parts = 1024;

pub fn Upload(comptime cfg: Config) type {
    const allowed = resolveTypes(cfg.allowed_types);
    return struct {
        const Self = @This();
        pub const kzig_upload = true;
        pub const config = cfg;

        files: []const File,
        fields: []const Field,

        /// The first file (KickJS `ctx.file`).
        pub fn file(self: Self) ?File {
            return if (self.files.len > 0) self.files[0] else null;
        }

        /// A text field's value.
        pub fn field(self: Self, name: []const u8) ?[]const u8 {
            for (self.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
            return null;
        }

        /// Not multipart → no files: the handler decides, as with multer.
        pub fn parse(ctx: *Ctx) !Self {
            const maybe = parts(ctx.arena, ctx.header("content-type") orelse "", ctx.req.body) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooManyParts => ctx.fail(.payload_too_large, "Too many form fields"),
                error.Malformed => ctx.fail(.bad_request, "Malformed multipart body"),
            };
            const all = maybe orelse return .{ .files = &.{}, .fields = &.{} };
            var files: std.ArrayList(File) = .empty;
            var fields: std.ArrayList(Field) = .empty;
            for (all) |p| {
                const client_name = p.filename orelse {
                    try fields.append(ctx.arena, .{ .name = p.name, .value = p.data });
                    continue;
                };
                // Other file fields are not this route's (KickJS filters by field).
                if (!std.mem.eql(u8, p.name, cfg.field)) continue;
                if (files.items.len == cfg.max_count)
                    return ctx.fail(.payload_too_large, try std.fmt.allocPrint(ctx.arena, "Too many files: at most {d}", .{cfg.max_count}));
                if (!typeAllowed(&allowed, p.content_type))
                    return ctx.fail(.unsupported_media_type, try std.fmt.allocPrint(ctx.arena, "File type {s} is not allowed", .{p.content_type}));
                const original = try originalName(ctx.arena, client_name);
                if (p.data.len > cfg.max_size)
                    return ctx.fail(.payload_too_large, try std.fmt.allocPrint(ctx.arena, "File {s} exceeds the {d}-byte limit", .{ original, cfg.max_size }));
                try files.append(ctx.arena, .{
                    .field = p.name,
                    .original_name = original,
                    .filename = try serverName(ctx.arena, uuid(ctx.io orelse return error.NoIo), original, p.content_type),
                    .content_type = p.content_type,
                    .data = p.data,
                });
            }
            return .{ .files = files.items, .fields = fields.items };
        }
    };
}

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: []const u8,
    data: []const u8,
};

/// The parts of a `multipart/form-data` body (RFC 7578); null for another
/// content type. Data slices point into `body`.
pub fn parts(a: Allocator, content_type: []const u8, body: []const u8) error{ Malformed, TooManyParts, OutOfMemory }!?[]const Part {
    const semi = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..semi], " \t"), "multipart/form-data")) return null;
    const boundary = param(a, content_type[semi..], "boundary") catch return error.Malformed;
    if (boundary == null or boundary.?.len == 0 or boundary.?.len > 70) return error.Malformed;
    const delim = try std.mem.concat(a, u8, &.{ "--", boundary.? });
    const close = try std.mem.concat(a, u8, &.{ "\r\n", delim });

    // Anything before the first delimiter is preamble.
    var pos = if (std.mem.startsWith(u8, body, delim))
        delim.len
    else
        (std.mem.find(u8, body, close) orelse return error.Malformed) + close.len;
    var out: std.ArrayList(Part) = .empty;
    while (true) {
        if (std.mem.startsWith(u8, body[pos..], "--")) return out.items;
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.Malformed;
        pos += 2;
        const head_end = std.mem.findPos(u8, body, pos, "\r\n\r\n") orelse return error.Malformed;
        const data_end = std.mem.findPos(u8, body, head_end + 4, close) orelse return error.Malformed;
        if (out.items.len == max_parts) return error.TooManyParts;
        try out.append(a, try part(a, body[pos..head_end], body[head_end + 4 .. data_end]));
        pos = data_end + close.len;
    }
}

fn part(a: Allocator, head: []const u8, data: []const u8) error{ Malformed, OutOfMemory }!Part {
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            const semi = std.mem.findScalar(u8, value, ';') orelse value.len;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..semi], " \t"), "form-data")) return error.Malformed;
            name = try param(a, value[semi..], "name");
            filename = try param(a, value[semi..], "filename");
        } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            content_type = value;
        }
    }
    return .{
        .name = name orelse return error.Malformed,
        .filename = filename,
        // RFC 7578 §4.4: text/plain unless said; a file defaults to bytes.
        .content_type = content_type orelse if (filename != null) "application/octet-stream" else "text/plain",
        .data = data,
    };
}

/// `; key=value` or `; key="quoted \" value"` from a header's parameters.
fn param(a: Allocator, params: []const u8, key: []const u8) error{ Malformed, OutOfMemory }!?[]const u8 {
    var i: usize = 0;
    while (i < params.len) {
        while (i < params.len and (params[i] == ';' or params[i] == ' ' or params[i] == '\t')) i += 1;
        const eq = std.mem.findScalarPos(u8, params, i, '=') orelse return null;
        const k = std.mem.trim(u8, params[i..eq], " \t");
        i = eq + 1;
        var value: []const u8 = undefined;
        if (i < params.len and params[i] == '"') {
            var buf: std.ArrayList(u8) = .empty;
            i += 1;
            while (true) : (i += 1) {
                if (i >= params.len) return error.Malformed;
                switch (params[i]) {
                    '"' => break,
                    // Only `\"` and `\\` are escapes: browsers send
                    // `C:\fakepath\a.png` as it is.
                    '\\' => if (i + 1 < params.len and (params[i + 1] == '"' or params[i + 1] == '\\')) {
                        i += 1;
                        try buf.append(a, params[i]);
                    } else try buf.append(a, '\\'),
                    else => |c| try buf.append(a, c),
                }
            }
            i += 1;
            value = buf.items;
        } else {
            const end = std.mem.findScalarPos(u8, params, i, ';') orelse params.len;
            value = std.mem.trim(u8, params[i..end], " \t");
            i = end;
        }
        if (std.ascii.eqlIgnoreCase(k, key)) return value;
    }
    return null;
}

/// The client's file name made safe to show (KickJS `normalizeOriginalName`).
pub fn originalName(a: Allocator, raw: []const u8) ![]const u8 {
    const base = raw[if (std.mem.findLastAny(u8, raw, "/\\")) |i| i + 1 else 0..];
    var out: std.ArrayList(u8) = .empty;
    for (base) |c| if (c >= 0x20 and c != 0x7f) try out.append(a, c);
    return std.mem.trim(u8, out.items, " \t");
}

/// `id` plus the client's extension when it names the file's own type:
/// `evil.html` sent as `image/png` gets none.
pub fn serverName(a: Allocator, id: [36]u8, original: []const u8, content_type: []const u8) ![]const u8 {
    const dot = std.mem.findScalarLast(u8, original, '.') orelse return a.dupe(u8, &id);
    if (dot == 0) return a.dupe(u8, &id);
    const ext = try std.ascii.allocLowerString(a, original[dot + 1 ..]);
    const known = mimeOf(ext) orelse return a.dupe(u8, &id);
    if (!std.ascii.eqlIgnoreCase(known, mediaType(content_type))) return a.dupe(u8, &id);
    return std.mem.concat(a, u8, &.{ &id, ".", ext });
}

pub fn resolveTypes(comptime types: []const []const u8) [types.len][]const u8 {
    var out: [types.len][]const u8 = undefined;
    for (types, &out) |t, *o| {
        var lower: [t.len]u8 = undefined;
        _ = std.ascii.lowerString(&lower, t);
        const ext = if (lower.len > 0 and lower[0] == '.') lower[1..] else &lower;
        const final = ext[0..ext.len].*;
        o.* = mimeOf(&final) orelse t;
    }
    return out;
}

pub fn typeAllowed(allowed: []const []const u8, content_type: []const u8) bool {
    if (allowed.len == 0) return true;
    const media = mediaType(content_type);
    for (allowed) |t| {
        if (std.mem.endsWith(u8, t, "/*")) {
            if (std.ascii.startsWithIgnoreCase(media, t[0 .. t.len - 1])) return true;
        } else if (std.ascii.eqlIgnoreCase(media, t)) return true;
    }
    return false;
}

fn mediaType(content_type: []const u8) []const u8 {
    return std.mem.trim(u8, content_type[0 .. std.mem.findScalar(u8, content_type, ';') orelse content_type.len], " \t");
}

/// A random (v4) UUID.
pub fn uuid(io: std.Io) [36]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0xf];
        o += 2;
    }
    return out;
}

/// KickJS's `MIME_MAP`: extension → type.
pub fn mimeOf(ext: []const u8) ?[]const u8 {
    return mime_map.get(ext);
}

const mime_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "jpg", "image/jpeg" },                                      .{ "jpeg", "image/jpeg" },
    .{ "png", "image/png" },                                       .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },                                     .{ "svg", "image/svg+xml" },
    .{ "bmp", "image/bmp" },                                       .{ "ico", "image/x-icon" },
    .{ "tiff", "image/tiff" },                                     .{ "tif", "image/tiff" },
    .{ "avif", "image/avif" },                                     .{ "pdf", "application/pdf" },
    .{ "doc", "application/msword" },                              .{ "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ "xls", "application/vnd.ms-excel" },                        .{ "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ "ppt", "application/vnd.ms-powerpoint" },                   .{ "pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ "odt", "application/vnd.oasis.opendocument.text" },         .{ "ods", "application/vnd.oasis.opendocument.spreadsheet" },
    .{ "odp", "application/vnd.oasis.opendocument.presentation" }, .{ "rtf", "application/rtf" },
    .{ "txt", "text/plain" },                                      .{ "csv", "text/csv" },
    .{ "zip", "application/zip" },                                 .{ "gz", "application/gzip" },
    .{ "tar", "application/x-tar" },                               .{ "rar", "application/vnd.rar" },
    .{ "7z", "application/x-7z-compressed" },                      .{ "mp3", "audio/mpeg" },
    .{ "wav", "audio/wav" },                                       .{ "ogg", "audio/ogg" },
    .{ "flac", "audio/flac" },                                     .{ "aac", "audio/aac" },
    .{ "mp4", "video/mp4" },                                       .{ "webm", "video/webm" },
    .{ "avi", "video/x-msvideo" },                                 .{ "mov", "video/quicktime" },
    .{ "mkv", "video/x-matroska" },                                .{ "json", "application/json" },
    .{ "xml", "application/xml" },                                 .{ "html", "text/html" },
});

const testing = std.testing;

fn form(comptime items: []const [3][]const u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (items) |p| {
            out = out ++ "--XyZ\r\nContent-Disposition: form-data; name=\"" ++ p[0] ++ "\"";
            if (p[1].len > 0) out = out ++ "; filename=\"" ++ p[1] ++ "\"\r\nContent-Type: " ++ p[2];
            out = out ++ "\r\n\r\n" ++ "DATA-" ++ p[0] ++ "\r\n";
        }
        break :blk out ++ "--XyZ--\r\n";
    };
}

const multipart_type: @import("../core/context.zig").Header = .{ .name = "content-type", .value = "multipart/form-data; boundary=XyZ" };

test "parts: files and fields, quoted names, the closing delimiter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = form(&.{ .{ "title", "", "" }, .{ "file", "C:\\fakepath\\pic.PNG", "image/png" } });
    const ps = (try parts(arena.allocator(), "multipart/form-data; boundary=\"XyZ\"", body)).?;
    try testing.expectEqual(2, ps.len);
    try testing.expectEqualStrings("title", ps[0].name);
    try testing.expectEqual(null, ps[0].filename);
    try testing.expectEqualStrings("DATA-title", ps[0].data);
    try testing.expectEqualStrings("C:\\fakepath\\pic.PNG", ps[1].filename.?);
    try testing.expectEqualStrings("image/png", ps[1].content_type);
    try testing.expectEqualStrings("DATA-file", ps[1].data);
}

test "parts: not multipart is null; a broken body is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try parts(a, "application/json", "{}"));
    try testing.expectError(error.Malformed, parts(a, "multipart/form-data", "--x\r\n"));
    try testing.expectError(error.Malformed, parts(a, "multipart/form-data; boundary=XyZ", "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nno end"));
    try testing.expectError(error.Malformed, parts(a, "multipart/form-data; boundary=XyZ", "--XyZ\r\nContent-Type: text/plain\r\n\r\nx\r\n--XyZ--"));
}

test "originalName drops directories and control characters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a.png", try originalName(arena.allocator(), "C:\\fakepath\\a.png"));
    try testing.expectEqualStrings("ab.txt", try originalName(arena.allocator(), " ../x/a\x00b.txt "));
}

test "serverName keeps an extension only when it names the file's type" {
    var id: [36]u8 = undefined;
    @memset(&id, 'u');
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(&id ++ ".png", try serverName(a, id, "photo.PNG", "image/png"));
    try testing.expectEqualStrings(&id, try serverName(a, id, "evil.html", "image/png"));
    try testing.expectEqualStrings(&id, try serverName(a, id, "noext", "image/png"));
}

test "typeAllowed: extensions, MIME types, wildcards, parameters ignored" {
    const allowed = comptime resolveTypes(&.{ "png", "application/pdf", "text/*" });
    try testing.expect(typeAllowed(&allowed, "image/png"));
    try testing.expect(typeAllowed(&allowed, "application/pdf"));
    try testing.expect(typeAllowed(&allowed, "text/plain; charset=utf-8"));
    try testing.expect(!typeAllowed(&allowed, "image/jpeg"));
    try testing.expect(typeAllowed(&.{}, "anything/at-all"));
}

const Doc = Upload(.{ .field = "file", .max_size = 16, .allowed_types = &.{ "png", "txt" } });
const Many = Upload(.{ .field = "file", .max_size = 16, .max_count = 2 });

const UploadController = struct {
    pub const routes = .{
        .{ .method = .POST, .path = "/one", .handler = "one" },
        .{ .method = .POST, .path = "/many", .handler = "many" },
        .{ .method = .POST, .path = "/typed/:n", .handler = "typed" },
    };
    pub fn typed(_: *UploadController, _: *@import("../core/context.zig").Ctx, got: struct { params: struct { n: u8 }, upload: Doc }) void {
        _ = got;
    }
    pub fn one(_: *UploadController, _: *@import("../core/context.zig").Ctx, got: struct { upload: Doc }) !struct { name: []const u8, size: usize, title: ?[]const u8, stored: []const u8 } {
        const f = got.upload.file() orelse return error.BadRequest;
        return .{ .name = f.original_name, .size = f.data.len, .title = got.upload.field("title"), .stored = f.filename };
    }
    pub fn many(_: *UploadController, _: *@import("../core/context.zig").Ctx, got: struct { upload: Many }) !struct { count: usize } {
        return .{ .count = got.upload.files.len };
    }
};

const UploadApp = @import("../core/app.zig").App(.{ .modules = &.{@import("../core/app.zig").Module(.{ .name = "Up", .path = "/up", .controllers = &.{UploadController} })} });

fn post(target: []const u8, body: []const u8) !kzig_testing.TestResponse {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NODE_ENV", "test");
    const app = try testing.allocator.create(UploadApp);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    return kzig_testing.request(testing.allocator, app, .{ .method = .POST, .target = target, .headers = &.{multipart_type}, .body = body });
}

test "upload route: the file, form fields and a generated name" {
    var res = try post("/api/v1/up/one", form(&.{ .{ "title", "", "" }, .{ "file", "pic.png", "image/png" } }));
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const got = try res.json(struct { name: []const u8, size: usize, title: ?[]const u8, stored: []const u8 });
    try testing.expectEqualStrings("pic.png", got.name);
    try testing.expectEqual("DATA-file".len, got.size);
    try testing.expectEqualStrings("DATA-title", got.title.?);
    try testing.expectEqual(36 + ".png".len, got.stored.len);
    try testing.expect(std.mem.endsWith(u8, got.stored, ".png"));
}

test "upload route: 415 for a type not allowed, 413 over the size or count, 400 malformed" {
    {
        var res = try post("/api/v1/up/one", form(&.{.{ "file", "x.html", "text/html" }}));
        defer res.deinit();
        try testing.expectEqual(.unsupported_media_type, res.status);
        try testing.expect(std.mem.find(u8, res.body, "File type text/html is not allowed") != null);
    }
    {
        const big = "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"b.png\"\r\nContent-Type: image/png\r\n\r\n" ++ @as([17]u8, @splat('x')) ++ "\r\n--XyZ--\r\n";
        var res = try post("/api/v1/up/one", big);
        defer res.deinit();
        try testing.expectEqual(.payload_too_large, res.status);
    }
    {
        var res = try post("/api/v1/up/many", form(&.{ .{ "file", "a.png", "image/png" }, .{ "file", "b.png", "image/png" }, .{ "file", "c.png", "image/png" } }));
        defer res.deinit();
        try testing.expectEqual(.payload_too_large, res.status);
        try testing.expect(std.mem.find(u8, res.body, "Too many files: at most 2") != null);
    }
    {
        var res = try post("/api/v1/up/one", "--XyZ\r\nbroken");
        defer res.deinit();
        try testing.expectEqual(.bad_request, res.status);
    }
}

test "upload route: files on other fields are ignored; no file is the handler's call" {
    var res = try post("/api/v1/up/many", form(&.{ .{ "file", "a.png", "image/png" }, .{ "other", "b.png", "image/png" } }));
    defer res.deinit();
    try testing.expectEqualStrings("{\"count\":1}", res.body);
}

test "upload route docs: a multipart body with the file as binary, 413 and 415" {
    const doc = inline for (UploadApp.routes) |r| {
        if (comptime std.mem.eql(u8, r.path, "/api/v1/up/one")) break r.doc.?;
    } else unreachable;
    try testing.expect(std.mem.find(u8, doc.operation, "\"requestBody\":{\"required\":true,\"content\":{\"multipart/form-data\":{\"schema\":{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"format\":\"binary\"}}}}}}") != null);
    try testing.expect(std.mem.find(u8, doc.operation, "\"413\"") != null);
    try testing.expect(std.mem.find(u8, doc.operation, "\"415\"") != null);
}

test "upload route: params are validated before the upload is read (KickJS order)" {
    var res = try post("/api/v1/up/typed/abc", form(&.{.{ "file", "x.html", "text/html" }}));
    defer res.deinit();
    try testing.expectEqual(.unprocessable_entity, res.status);
}
