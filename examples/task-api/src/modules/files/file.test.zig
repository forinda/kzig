//! file-storage-api's `file.test.ts`: the same paths and statuses, on
//! memory storage (KickJS overrides STORAGE with `memoryStorage()`).
const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");
const Clock = @import("file.service.zig").Clock;
const FileStorage = @import("file.storage.zig").FileStorage;

const testing = std.testing;
const key = "test-api-key-0123456789abcdef0123456789";
const bearer: kzig.Header = .{ .name = "authorization", .value = "Bearer " ++ key };
const multipart: kzig.Header = .{ .name = "content-type", .value = "multipart/form-data; boundary=kzig" };
const png = "\x89PNG\r\n\x1a\n\x01\x02\x03";

fn form(comptime filename: []const u8, comptime content_type: []const u8, data: []const u8) ![]u8 {
    return std.mem.concat(testing.allocator, u8, &.{
        "--kzig\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" ++ filename ++ "\"\r\nContent-Type: " ++ content_type ++ "\r\n\r\n",
        data,
        "\r\n--kzig--\r\n",
    });
}

const Files = struct {
    t: test_app.TestApp,

    fn init(self: *Files, max_bytes: []const u8) !void {
        self.t = try test_app.boot(&.{ .{ "STORAGE_DRIVER", "memory" }, .{ "API_KEY", key }, .{ "MAX_UPLOAD_BYTES", max_bytes } });
    }

    fn deinit(self: *Files) void {
        self.t.deinit();
    }

    fn upload(self: *Files, body: []const u8) !kzig.testing.TestResponse {
        return self.t.request(.{ .method = .POST, .target = "/api/v1/files", .headers = &.{ bearer, multipart }, .body = body });
    }

    fn api(self: *Files, method: std.http.Method, target: []const u8) !kzig.testing.TestResponse {
        return self.t.request(.{ .method = method, .target = target, .headers = &.{bearer} });
    }

    fn uploadPng(self: *Files) ![]const u8 {
        const body = try form("pic.png", "image/png", png);
        defer testing.allocator.free(body);
        var res = try self.upload(body);
        defer res.deinit();
        try testing.expectEqual(.created, res.status);
        const parsed = try std.json.parseFromSlice(struct { id: []const u8 }, testing.allocator, res.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return testing.allocator.dupe(u8, parsed.value.id);
    }
};

const Uploaded = struct { id: []const u8, size: usize, contentType: []const u8 };

test "files: uploads, lists, downloads and deletes a file" {
    var f: Files = undefined;
    try f.init("5242880");
    defer f.deinit();

    const body = try form("pic.png", "image/png", png);
    defer testing.allocator.free(body);
    var up = try f.upload(body);
    defer up.deinit();
    try testing.expectEqual(.created, up.status);
    const file = try up.json(Uploaded);
    try testing.expectEqual(png.len, file.size);
    try testing.expectEqualStrings("image/png", file.contentType);
    try testing.expect(std.mem.endsWith(u8, file.id, ".png"));
    const stored = try std.fmt.allocPrint(testing.allocator, "files/{s}", .{file.id});
    defer testing.allocator.free(stored);
    try testing.expect(try f.t.app.get(FileStorage).storage().exists(stored));

    var list = try f.api(.GET, "/api/v1/files");
    defer list.deinit();
    const listed = try list.json(struct { files: []const struct { id: []const u8 } });
    try testing.expectEqual(1, listed.files.len);
    try testing.expectEqualStrings(file.id, listed.files[0].id);

    const path = try std.fmt.allocPrint(testing.allocator, "/api/v1/files/{s}", .{file.id});
    defer testing.allocator.free(path);
    var down = try f.api(.GET, path);
    defer down.deinit();
    try testing.expectEqual(.ok, down.status);
    try testing.expectEqualStrings("image/png", down.header("content-type").?);
    try testing.expectEqualStrings("nosniff", down.header("x-content-type-options").?);
    try testing.expectEqualStrings(png, down.body);

    var deleted = try f.api(.DELETE, path);
    defer deleted.deinit();
    try testing.expectEqual(.no_content, deleted.status);
    var gone = try f.api(.GET, path);
    defer gone.deinit();
    try testing.expectEqual(.not_found, gone.status);
    var again = try f.api(.DELETE, path);
    defer again.deinit();
    try testing.expectEqual(.not_found, again.status);
}

test "files: 413 for a file over the limit and 415 for a type not allowed" {
    var f: Files = undefined;
    try f.init("8");
    defer f.deinit();
    const big = try form("big.png", "image/png", png);
    defer testing.allocator.free(big);
    var too_big = try f.upload(big);
    defer too_big.deinit();
    try testing.expectEqual(.payload_too_large, too_big.status);
    const html = try form("x.html", "text/html", "<script>");
    defer testing.allocator.free(html);
    var wrong_type = try f.upload(html);
    defer wrong_type.deinit();
    try testing.expectEqual(.unsupported_media_type, wrong_type.status);

    var list = try f.api(.GET, "/api/v1/files");
    defer list.deinit();
    try testing.expectEqual(0, (try list.json(struct { files: []const struct { id: []const u8 } })).files.len);
}

test "files: requires the API key" {
    var f: Files = undefined;
    try f.init("5242880");
    defer f.deinit();
    var none = try f.t.get("/api/v1/files");
    defer none.deinit();
    try testing.expectEqual(.unauthorized, none.status);
    const body = try form("pic.png", "image/png", png);
    defer testing.allocator.free(body);
    var post = try f.t.request(.{ .method = .POST, .target = "/api/v1/files", .headers = &.{multipart}, .body = body });
    defer post.deinit();
    try testing.expectEqual(.unauthorized, post.status);
    var wrong = try f.t.request(.{ .target = "/api/v1/files", .headers = &.{.{ .name = "authorization", .value = "Bearer nope" }} });
    defer wrong.deinit();
    try testing.expectEqual(.unauthorized, wrong.status);
}

/// Path and query of a signed URL, to call it through the test client.
fn pathOf(url: []const u8) []const u8 {
    const after_scheme = std.mem.find(u8, url, "://").? + 3;
    return url[std.mem.findScalarPos(u8, url, after_scheme, '/').?..];
}

test "files: serves a signed URL without the API key until it expires" {
    var f: Files = undefined;
    try f.init("5242880");
    defer f.deinit();
    const id = try f.uploadPng();
    defer testing.allocator.free(id);

    const target = try std.fmt.allocPrint(testing.allocator, "/api/v1/files/{s}/url?expiresIn=60", .{id});
    defer testing.allocator.free(target);
    var signed = try f.api(.GET, target);
    defer signed.deinit();
    try testing.expectEqual(.ok, signed.status);
    const link = try signed.json(struct { url: []const u8, expiresAt: []const u8 });
    const path = pathOf(link.url);

    var ok = try f.t.get(path);
    defer ok.deinit();
    try testing.expectEqual(.ok, ok.status);
    try testing.expectEqualStrings(png, ok.body);

    // Tampered: another file's id, or a later expiry, with the same signature.
    const other_id = try std.mem.replaceOwned(u8, testing.allocator, path, id, "00000000-0000-0000-0000-000000000000.png");
    defer testing.allocator.free(other_id);
    var forged_id = try f.t.get(other_id);
    defer forged_id.deinit();
    try testing.expectEqual(.forbidden, forged_id.status);
    const at = std.mem.find(u8, path, "expires=").? + "expires=".len;
    const end = std.mem.findScalarPos(u8, path, at, '&').?;
    const later = try std.mem.concat(testing.allocator, u8, &.{ path[0..at], "9999999999", path[end..] });
    defer testing.allocator.free(later);
    var forged_expiry = try f.t.get(later);
    defer forged_expiry.deinit();
    try testing.expectEqual(.forbidden, forged_expiry.status);

    // Expired.
    f.t.app.get(Clock).offset_s = 61;
    var expired = try f.t.get(path);
    defer expired.deinit();
    try testing.expectEqual(.forbidden, expired.status);
}

test "files: refuses a signed URL for a missing file and an id that is not ours" {
    var f: Files = undefined;
    try f.init("5242880");
    defer f.deinit();
    var missing = try f.api(.GET, "/api/v1/files/00000000-0000-0000-0000-000000000000.png/url");
    defer missing.deinit();
    try testing.expectEqual(.not_found, missing.status);
    // kzig refuses `..` in a decoded path at the router (KickJS: 422 from validation).
    var escape = try f.api(.GET, "/api/v1/files/..%2Fsecret/url");
    defer escape.deinit();
    try testing.expectEqual(.bad_request, escape.status);
    var not_ours = try f.api(.GET, "/api/v1/files/secret.txt/url");
    defer not_ours.deinit();
    try testing.expectEqual(.unprocessable_entity, not_ours.status);
}

test "files: storage:<driver> on /health/ready" {
    var f: Files = undefined;
    try f.init("5242880");
    defer f.deinit();
    var res = try f.t.get("/health/ready");
    defer res.deinit();
    try testing.expect(std.mem.find(u8, res.body, "{\"name\":\"storage:memory\",\"status\":\"up\"}") != null);
}

test "files: production defaults to S3 and won't boot without S3_BUCKET" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("DB_FILE", ":memory:"); // not ./data/app.db
    for ([_][2][]const u8{
        .{ "NODE_ENV", "production" },                               .{ "APP_PUBLIC_URL", "https://api.example.com" },
        .{ "TRANSACTIONAL_MAIL_PASSWORD", "a-long-password" },       .{ "TRANSACTIONAL_MAIL_FROM", "a@example.com" },
        .{ "MARKETING_MAIL_PASSWORD", "a-long-password" },           .{ "MARKETING_MAIL_FROM", "a@example.com" },
        .{ "API_KEY", "prod-api-key-0123456789abcdef0123456" },      .{ "SIGNING_SECRET", "prod-signing-secret-0123456789abcdef" },
        .{ "CHAT_SECRET", "prod-chat-secret-0123456789abcdef0123" }, .{ "CRON_SECRET", "prod-cron-secret-0123456789" },
    }) |v| try env.put(v[0], v[1]);
    const App = @import("../../main.zig").App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try testing.expectError(error.MissingS3Settings, app.init(testing.io, testing.allocator, &env));
}

test "files: disk storage stays healthy once it holds files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const t = try test_app.boot(&.{ .{ "STORAGE_DRIVER", "disk" }, .{ "UPLOAD_DIR", dir }, .{ "API_KEY", key } });
    defer t.deinit();
    const body = try form("pic.png", "image/png", png);
    defer testing.allocator.free(body);
    var up = try t.request(.{ .method = .POST, .target = "/api/v1/files", .headers = &.{ bearer, multipart }, .body = body });
    defer up.deinit();
    try testing.expectEqual(.created, up.status);
    var res = try t.get("/health/ready");
    defer res.deinit();
    try testing.expect(std.mem.find(u8, res.body, "{\"name\":\"storage:disk\",\"status\":\"up\"}") != null);
}
