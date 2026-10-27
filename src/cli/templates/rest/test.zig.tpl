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
