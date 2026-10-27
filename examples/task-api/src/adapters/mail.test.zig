const std = @import("std");
const kzig = @import("kzig");
const App = @import("../main.zig").App;
const mail = @import("mail.settings.zig");

const testing = std.testing;

const production = [_][2][]const u8{
    .{ "NODE_ENV", "production" },
    .{ "APP_PUBLIC_URL", "https://api.example.com" },
    .{ "TRANSACTIONAL_MAIL_FROM", "noreply@example.com" },
    .{ "MARKETING_MAIL_FROM", "news@example.com" },
    .{ "MARKETING_MAIL_PASSWORD", "marketing-secret" },
    .{ "API_KEY", "prod-api-key-0123456789abcdef0123456" },
    .{ "SIGNING_SECRET", "prod-signing-secret-0123456789abcdef" },
    .{ "CHAT_SECRET", "prod-chat-secret-0123456789abcdef0123" },
};

fn envOf(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

/// The issues one section reports for `env`, as the boot log lists them.
fn issuesFor(comptime S: type, env: *const std.process.Environ.Map, arena: std.mem.Allocator) ![]const kzig.config.Issue {
    var issues: std.ArrayList(kzig.config.Issue) = .empty;
    _ = kzig.config.parseSection(S, arena, testing.io, env, &issues, null) catch {};
    return issues.items;
}

fn expectRefused(pairs: []const [2][]const u8) !void {
    var env = try envOf(pairs);
    defer env.deinit();
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try testing.expectError(error.InvalidConfig, app.init(testing.io, testing.allocator, &env));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const issues = try issuesFor(mail.TransactionalMail, &env, arena.allocator());
    try testing.expectEqual(1, issues.len);
    try testing.expectEqualStrings("TRANSACTIONAL_MAIL_PASSWORD", issues[0].key);
}

test "refuses to boot in production without the SMTP password, naming the variable" {
    try expectRefused(&production);
}

test "fails closed with NODE_ENV unset — no dev default for the secret" {
    try expectRefused(production[1..]);
}

test "boots in production once the password comes from a _FILE secret" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "smtp_password", .data = "from-a-mounted-secret\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "smtp_password", testing.allocator);
    defer testing.allocator.free(path);

    var env = try envOf(&production);
    defer env.deinit();
    try env.put("TRANSACTIONAL_MAIL_PASSWORD_FILE", path);
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();

    try testing.expectEqualStrings("from-a-mounted-secret", app.get(mail.TransactionalMail).password);
    for (app.get(kzig.ConfigReport).vars) |v| if (std.mem.eql(u8, v.name, "TRANSACTIONAL_MAIL_PASSWORD")) {
        try testing.expectEqual(kzig.config.Origin.Kind.file, v.origin);
    };
}

test "falls back to dev defaults outside production" {
    const t = try @import("../test_app.zig").boot(&.{});
    defer t.deinit();
    const m = t.app.get(mail.TransactionalMail);
    try testing.expectEqual(1025, m.port);
    try testing.expectEqualStrings("dev-mail-password", m.password);
}

test "a password shorter than 8 characters is refused" {
    var env = try envOf(&.{ .{ "NODE_ENV", "test" }, .{ "TRANSACTIONAL_MAIL_PASSWORD", "short" } });
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const issues = try issuesFor(mail.TransactionalMail, &env, arena.allocator());
    try testing.expectEqualStrings("TRANSACTIONAL_MAIL_PASSWORD", issues[0].key);
    try testing.expectEqualStrings("must be at least 8 characters", issues[0].reason);
}

test "ready reports each mail adapter" {
    // Port 1 is never an SMTP server: both checks are down.
    const t = try @import("../test_app.zig").boot(&.{ .{ "TRANSACTIONAL_MAIL_PORT", "1" }, .{ "MARKETING_MAIL_PORT", "1" } });
    defer t.deinit();
    var res = try t.get("/health/ready");
    defer res.deinit();
    try testing.expectEqual(.service_unavailable, res.status);
    try testing.expectEqualStrings("{\"status\":\"degraded\",\"checks\":[" ++
        "{\"name\":\"MailAdapter:transactional\",\"status\":\"down\"},{\"name\":\"MailAdapter:marketing\",\"status\":\"down\"}]}", res.body);
}
