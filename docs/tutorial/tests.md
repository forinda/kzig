# 6. Tests

`kzig.testing` runs a request through the whole app (router, middleware, contributors,
validation, the handler, the database) without a socket. Each test boots its own app, so give
each its own database: an in-memory one, migrated at boot like the real one.

```zig
// src/test_app.zig, in bootWith
try env.put("NODE_ENV", "test");
// A fresh database per test, migrated at boot.
try env.put("DB_FILE", ":memory:");
for (vars) |v| try env.put(v[0], v[1]);
```

The generated test spoke the in-memory repository's shape; this one speaks the new one:

```zig title="src/modules/bookmarks/bookmark.test.zig"
const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");

const testing = std.testing;
const json: kzig.Header = .{ .name = "content-type", .value = "application/json" };
const key: kzig.Header = .{ .name = "authorization", .value = "Bearer dev-api-key-change-me-0123456789ab" };
const Bookmark = struct { id: i32, url: []const u8, title: []const u8, notes: ?[]const u8 };

test "bookmarks: create, read, search, update, delete" {
    const t = try test_app.boot(&.{});
    defer t.deinit();

    var created = try t.request(.{ .method = .POST, .target = "/api/v1/bookmarks", .headers = &.{ json, key }, .body =
        \\{"url":"https://ziglang.org","title":"Zig","notes":"the language"}
    });
    defer created.deinit();
    try testing.expectEqual(.created, created.status);
    const id = (try created.json(Bookmark)).id;
    const path = try std.fmt.allocPrint(testing.allocator, "/api/v1/bookmarks/{d}", .{id});
    defer testing.allocator.free(path);

    var got = try t.get(path);
    defer got.deinit();
    try testing.expectEqualStrings("Zig", (try got.json(Bookmark)).title);

    var updated = try t.request(.{ .method = .PATCH, .target = path, .headers = &.{ json, key }, .body = "{\"notes\":\"fast\"}" });
    defer updated.deinit();
    const after = try updated.json(Bookmark);
    try testing.expectEqualStrings("fast", after.notes.?);
    try testing.expectEqualStrings("Zig", after.title); // untouched

    var found = try t.get("/api/v1/bookmarks?q=zi");
    defer found.deinit();
    try testing.expectEqual(1, (try found.json(struct { meta: struct { total: usize } })).meta.total);

    var deleted = try t.request(.{ .method = .DELETE, .target = path, .headers = &.{key} });
    defer deleted.deinit();
    try testing.expectEqual(.no_content, deleted.status);

    var gone = try t.get(path);
    defer gone.deinit();
    try testing.expectEqual(.not_found, gone.status);
}

test "bookmarks: writes need the API key; reads don't" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.request(.{ .method = .POST, .target = "/api/v1/bookmarks", .headers = &.{json}, .body = "{\"url\":\"https://x.dev\",\"title\":\"x\"}" });
    defer res.deinit();
    try testing.expectEqual(.unauthorized, res.status);
    var list = try t.get("/api/v1/bookmarks");
    defer list.deinit();
    try testing.expectEqual(.ok, list.status);
}

test "bookmarks: a bad body is 422 with every field; a URL saved twice is 409" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var bad = try t.request(.{ .method = .POST, .target = "/api/v1/bookmarks", .headers = &.{ json, key }, .body = "{\"url\":\"ftp://x\",\"title\":\"\"}" });
    defer bad.deinit();
    try testing.expectEqual(.unprocessable_entity, bad.status);
    try testing.expectEqual(2, (try bad.json(struct { errors: []const kzig.FieldError })).errors.len);

    const body = "{\"url\":\"https://ziglang.org\",\"title\":\"Zig\"}";
    var first = try t.request(.{ .method = .POST, .target = "/api/v1/bookmarks", .headers = &.{ json, key }, .body = body });
    defer first.deinit();
    var again = try t.request(.{ .method = .POST, .target = "/api/v1/bookmarks", .headers = &.{ json, key }, .body = body });
    defer again.deinit();
    try testing.expectEqual(.conflict, again.status);
}

test "production refuses to start without an API key" {
    try testing.expectError(error.InvalidConfig, test_app.boot(&.{.{ "NODE_ENV", "production" }}));
}
```

```console
$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 7/7 tests passed
```

`std.testing.allocator` checks every test for leaks: a request arena not freed, or a service
that forgot its `deinit`, fails the run.

Next, [production](production.md).
