//! task-kickdb-api's workspaces: plain reads, and the relational ones
//! (owner, members with their users, projects) in one query each. The
//! database tests run when `DATABASE_URL` is set.
const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");

const testing = std.testing;
const json: kzig.Header = .{ .name = "content-type", .value = "application/json" };
const migrations: [2][]const u8 = .{ "MIGRATIONS_DIR", "examples/task-api/db/migrations" };

fn databaseUrl(env: *std.process.Environ.Map) ?[]const u8 {
    env.* = testing.environ.createMap(testing.allocator) catch return null;
    return env.get("DATABASE_URL");
}

test "workspaces: without a database the routes are unavailable (503)" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    if (databaseUrl(&env) != null) return error.SkipZigTest;
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/workspaces");
    defer res.deinit();
    try testing.expectEqual(.service_unavailable, res.status);
}

test "workspaces: create, read, and read with owner, members and projects in one query" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    const url = databaseUrl(&env) orelse return error.SkipZigTest;
    const t = try test_app.boot(&.{ .{ "DATABASE_URL", url }, migrations });
    defer t.deinit();
    const a = testing.allocator;

    const now = std.Io.Clock.real.now(testing.io).toNanoseconds();
    const user_body = try std.fmt.allocPrint(a, "{{\"email\":\"owner+{d}@example.com\",\"passwordHash\":\"h\",\"firstName\":\"Ada\",\"lastName\":\"L\"}}", .{now});
    defer a.free(user_body);
    var user = try t.request(.{ .method = .POST, .target = "/api/v1/users", .headers = &.{json}, .body = user_body });
    defer user.deinit();
    try testing.expectEqual(.created, user.status);
    const owner_id = (try user.json(struct { id: []const u8 })).id;

    const ws_body = try std.fmt.allocPrint(a, "{{\"name\":\"Core\",\"slug\":\"core-{d}\",\"ownerId\":\"{s}\"}}", .{ now, owner_id });
    defer a.free(ws_body);
    var created = try t.request(.{ .method = .POST, .target = "/api/v1/workspaces", .headers = &.{json}, .body = ws_body });
    defer created.deinit();
    try testing.expectEqual(.created, created.status);
    const id = (try created.json(struct { id: []const u8 })).id;

    const one = try std.fmt.allocPrint(a, "/api/v1/workspaces/{s}", .{id});
    defer a.free(one);
    var show = try t.get(one);
    defer show.deinit();
    try testing.expectEqual(.ok, show.status);
    try testing.expect(std.mem.find(u8, show.body, "\"name\":\"Core\"") != null);

    const full = try std.fmt.allocPrint(a, "/api/v1/workspaces/{s}/full", .{id});
    defer a.free(full);
    var res = try t.get(full);
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    try testing.expect(std.mem.find(u8, res.body, "\"owner\":{") != null);
    try testing.expect(std.mem.find(u8, res.body, "\"firstName\":\"Ada\"") != null);
    try testing.expect(std.mem.find(u8, res.body, "\"members\":[]") != null);
    try testing.expect(std.mem.find(u8, res.body, "\"projects\":[]") != null);
    // The owner's hash is left out, as task-kickdb-api leaves it out.
    try testing.expect(std.mem.find(u8, res.body, "passwordHash") == null);

    const owned = try std.fmt.allocPrint(a, "/api/v1/workspaces/owned-by/{s}", .{owner_id});
    defer a.free(owned);
    var list = try t.get(owned);
    defer list.deinit();
    try testing.expectEqual(.ok, list.status);
    try testing.expect(std.mem.find(u8, list.body, id) != null);

    var missing = try t.get("/api/v1/workspaces/00000000-0000-0000-0000-000000000000/full");
    defer missing.deinit();
    try testing.expectEqual(.not_found, missing.status);
    var all = try t.get("/api/v1/workspaces");
    defer all.deinit();
    try testing.expect(std.mem.find(u8, all.body, id) != null);
}
