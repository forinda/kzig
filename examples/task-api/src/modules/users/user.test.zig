//! task-kickdb-api's `user.test.ts`: the database tests run when
//! `DATABASE_URL` is set (CI runs Postgres).
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

test "users: without a database the routes are unavailable (503) and ready leaves postgres out" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    if (databaseUrl(&env) != null) return error.SkipZigTest;
    const t = try test_app.boot(&.{});
    defer t.deinit();
    var res = try t.get("/api/v1/users");
    defer res.deinit();
    try testing.expectEqual(.service_unavailable, res.status);
    var ready = try t.get("/health/ready");
    defer ready.deinit();
    try testing.expect(std.mem.find(u8, ready.body, "postgres") == null);
}

test "users: a password hash longer than its column is 422, not a database error" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    const url = databaseUrl(&env);
    const t = try test_app.boot(if (url) |u| &.{ .{ "DATABASE_URL", u }, migrations } else &.{});
    defer t.deinit();
    const hash: [256]u8 = @splat('h');
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"email\":\"long@example.com\",\"passwordHash\":\"{s}\",\"firstName\":\"Ada\",\"lastName\":\"Lovelace\"}}", .{&hash});
    defer testing.allocator.free(body);
    var res = try t.request(.{ .method = .POST, .target = "/api/v1/users", .headers = &.{json}, .body = body });
    defer res.deinit();
    try testing.expectEqual(.unprocessable_entity, res.status);
    try testing.expect(std.mem.find(u8, res.body, "passwordHash") != null);
}

test "users: creates a user and reads it back" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    const url = databaseUrl(&env) orelse return error.SkipZigTest;
    const t = try test_app.boot(&.{ .{ "DATABASE_URL", url }, migrations });
    defer t.deinit();

    var buf: [128]u8 = undefined;
    const now = std.Io.Clock.real.now(testing.io).toNanoseconds();
    const email = try std.fmt.bufPrint(&buf, "ada+{d}@example.com", .{now});
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"email\":\"{s}\",\"passwordHash\":\"x\",\"firstName\":\"Ada\",\"lastName\":\"Lovelace\"}}", .{email});
    defer testing.allocator.free(body);
    var created = try t.request(.{ .method = .POST, .target = "/api/v1/users", .headers = &.{json}, .body = body });
    defer created.deinit();
    try testing.expectEqual(.created, created.status);
    // The hash never reaches a response.
    try testing.expect(std.mem.find(u8, created.body, "passwordHash") == null);
    const id = (try created.json(struct { id: []const u8 })).id;

    const path = try std.fmt.allocPrint(testing.allocator, "/api/v1/users/{s}", .{id});
    defer testing.allocator.free(path);
    var got = try t.get(path);
    defer got.deinit();
    try testing.expectEqual(.ok, got.status);
    const user = try got.json(struct { email: []const u8, firstName: []const u8 });
    try testing.expectEqualStrings(email, user.email);
    try testing.expectEqualStrings("Ada", user.firstName);

    // The same email again: the unique index answers 409.
    var again = try t.request(.{ .method = .POST, .target = "/api/v1/users", .headers = &.{json}, .body = body });
    defer again.deinit();
    try testing.expectEqual(.conflict, again.status);

    var missing = try t.get("/api/v1/users/00000000-0000-0000-0000-000000000000");
    defer missing.deinit();
    try testing.expectEqual(.not_found, missing.status);
    var list = try t.get("/api/v1/users");
    defer list.deinit();
    try testing.expect(std.mem.find(u8, list.body, email) != null);
    var ready = try t.get("/health/ready");
    defer ready.deinit();
    try testing.expect(std.mem.find(u8, ready.body, "{\"name\":\"postgres\",\"status\":\"up\"}") != null);
}

test "users: production refuses to boot with pending migrations" {
    var env: std.process.Environ.Map = undefined;
    defer env.deinit();
    _ = databaseUrl(&env) orelse return error.SkipZigTest;
    // An empty migrations folder elsewhere: nothing pending, so a fresh one is.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "99990101_000000_never_applied");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "99990101_000000_never_applied/up.sql", .data = "SELECT 1;" });
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    var app_env: std.process.Environ.Map = .init(testing.allocator);
    defer app_env.deinit();
    for ([_][2][]const u8{
        .{ "NODE_ENV", "production" },                               .{ "APP_PUBLIC_URL", "https://api.example.com" },
        .{ "TRANSACTIONAL_MAIL_PASSWORD", "a-long-password" },       .{ "TRANSACTIONAL_MAIL_FROM", "a@example.com" },
        .{ "MARKETING_MAIL_PASSWORD", "a-long-password" },           .{ "MARKETING_MAIL_FROM", "a@example.com" },
        .{ "API_KEY", "prod-api-key-0123456789abcdef0123456" },      .{ "SIGNING_SECRET", "prod-signing-secret-0123456789abcdef" },
        .{ "CHAT_SECRET", "prod-chat-secret-0123456789abcdef0123" }, .{ "CRON_SECRET", "prod-cron-secret-0123456789" },
        .{ "STORAGE_DRIVER", "disk" },                               .{ "DATABASE_URL", env.get("DATABASE_URL").? },
        .{ "MIGRATIONS_DIR", dir },
    }) |v| try app_env.put(v[0], v[1]);
    const App = @import("../../main.zig").App;
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try testing.expectError(error.PendingMigrations, app.init(testing.io, testing.allocator, &app_env));
}
