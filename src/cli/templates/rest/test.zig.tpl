const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");

const testing = std.testing;
const json: kzig.Header = .{ .name = "content-type", .value = "application/json" };
const {{Pascal}} = struct { id: u64, name: []const u8 };

test "{{plural}}: create, read, list, update, delete" {
    const t = try test_app.boot(&.{});
    defer t.deinit();

    var created = try t.request(.{ .method = .POST, .target = "/api/v1/{{plural}}", .headers = &.{json}, .body = "{\"name\":\"First\"}" });
    defer created.deinit();
    try testing.expectEqual(.created, created.status);
    const id = (try created.json({{Pascal}})).id;
    const path = try std.fmt.allocPrint(testing.allocator, "/api/v1/{{plural}}/{d}", .{id});
    defer testing.allocator.free(path);

    var got = try t.get(path);
    defer got.deinit();
    try testing.expectEqualStrings("First", (try got.json({{Pascal}})).name);

    var updated = try t.request(.{ .method = .PATCH, .target = path, .headers = &.{json}, .body = "{\"name\":\"Renamed\"}" });
    defer updated.deinit();
    try testing.expectEqualStrings("Renamed", (try updated.json({{Pascal}})).name);

    var list = try t.get("/api/v1/{{plural}}?q=ren&sort=-created_at");
    defer list.deinit();
    const page = try list.json(struct { data: []const {{Pascal}}, meta: struct { total: usize } });
    try testing.expectEqual(1, page.meta.total);

    var deleted = try t.request(.{ .method = .DELETE, .target = path });
    defer deleted.deinit();
    try testing.expectEqual(.no_content, deleted.status);

    var gone = try t.get(path);
    defer gone.deinit();
    try testing.expectEqual(.not_found, gone.status);
}

test "{{plural}}: invalid input is 422" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.request(.{ .method = .POST, .target = "/api/v1/{{plural}}", .headers = &.{json}, .body = "{\"name\":\"\"}" });
    defer res.deinit();
    try testing.expectEqual(.unprocessable_entity, res.status);
}

test "{{plural}}: search, filter and sort over several rows" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    for ([_][]const u8{ "Beta", "Alpha", "Alphabet" }) |name| {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"name\":\"{s}\"}}", .{name});
        defer testing.allocator.free(body);
        var res = try t.request(.{ .method = .POST, .target = "/api/v1/{{plural}}", .headers = &.{json}, .body = body });
        defer res.deinit();
        try testing.expectEqual(.created, res.status);
    }
    const ListBody = struct { data: []const {{Pascal}}, meta: struct { total: usize } };

    var searched = try t.get("/api/v1/{{plural}}?q=alpha");
    defer searched.deinit();
    try testing.expectEqual(2, (try searched.json(ListBody)).meta.total);

    var filtered = try t.get("/api/v1/{{plural}}?filter=name:eq:Beta");
    defer filtered.deinit();
    const one = try filtered.json(ListBody);
    try testing.expectEqual(1, one.meta.total);
    try testing.expectEqualStrings("Beta", one.data[0].name);

    var sorted = try t.get("/api/v1/{{plural}}?sort=-name");
    defer sorted.deinit();
    const rows = (try sorted.json(ListBody)).data;
    try testing.expectEqual(3, rows.len);
    for (rows, [_][]const u8{ "Beta", "Alphabet", "Alpha" }) |row, name| try testing.expectEqualStrings(name, row.name);
}

test "{{plural}}: a filter operator name doesn't support is 400" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/{{plural}}?filter=name:gt:m");
    defer res.deinit();
    try testing.expectEqual(.bad_request, res.status);
}

test "{{plural}}: the /:id routes document 404" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/openapi.json");
    defer res.deinit();
    const spec = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.body, .{});
    defer spec.deinit();
    const item = spec.value.object.get("paths").?.object.get("/api/v1/{{plural}}/{id}").?.object;
    for ([_][]const u8{ "get", "patch", "delete" }) |method|
        try testing.expect(item.get(method).?.object.get("responses").?.object.contains("404"));
}
