const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");

const testing = std.testing;
const Header = kzig.Header;

const auth: Header = .{ .name = "authorization", .value = "Bearer token-all" };
const acme_only: Header = .{ .name = "authorization", .value = "Bearer token-acme" };
const json_body: Header = .{ .name = "content-type", .value = "application/json" };

/// The archive's SQLite database, in memory, migrated on boot (needs -Dsqlite).
fn boot() !test_app.TestApp {
    if (!kzig.db.sqlite_built) return error.SkipZigTest;
    return test_app.boot(&.{});
}

fn tenant(slug: []const u8) Header {
    return .{ .name = "x-tenant", .value = slug };
}
fn host(h: []const u8) Header {
    return .{ .name = "host", .value = h };
}

const Project = struct { id: []const u8, workspaceId: []const u8, title: []const u8 };
const List = struct { tenant: []const u8, projects: []const Project };

test "rejects requests without a token" {
    const t = try boot();
    defer t.deinit();
    var res = try t.request(.{ .target = "/api/v1/projects", .headers = &.{tenant("acme")} });
    defer res.deinit();
    try testing.expectEqual(.unauthorized, res.status);
}

test "answers 404 for an unknown tenant" {
    const t = try boot();
    defer t.deinit();
    var res = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ tenant("nope"), auth } });
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
}

test "answers a tenant the user does not belong to like an unknown one (404, no enumeration)" {
    const t = try boot();
    defer t.deinit();
    var ok = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ tenant("acme"), acme_only } });
    defer ok.deinit();
    try testing.expectEqual(.ok, ok.status);
    var other = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ tenant("globex"), acme_only } });
    defer other.deinit();
    try testing.expectEqual(.not_found, other.status);
    var post = try t.request(.{ .method = .POST, .target = "/api/v1/projects", .headers = &.{ host("globex.localhost"), acme_only, json_body }, .body = "{\"title\":\"Not mine\"}" });
    defer post.deinit();
    try testing.expectEqual(.not_found, post.status);
}

test "keeps each tenant's projects apart" {
    const t = try boot();
    defer t.deinit();
    var created = try t.request(.{ .method = .POST, .target = "/api/v1/projects", .headers = &.{ tenant("acme"), auth, json_body }, .body = "{\"title\":\"Rocket skates\"}" });
    defer created.deinit();
    try testing.expectEqual(.created, created.status);
    try testing.expectEqualStrings("tenant-acme", (try created.json(Project)).workspaceId);

    var acme = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ tenant("acme"), auth } });
    defer acme.deinit();
    const a = try acme.json(List);
    try testing.expectEqualStrings("Acme Corp", a.tenant);
    try testing.expectEqual(1, a.projects.len);
    try testing.expectEqualStrings("Rocket skates", a.projects[0].title);

    var globex = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ host("globex.localhost"), auth } });
    defer globex.deinit();
    try testing.expectEqual(.ok, globex.status);
    try testing.expectEqual(0, (try globex.json(List)).projects.len);
}

fn import(t: test_app.TestApp, slug: []const u8, titles: []const []const u8) !kzig.testing.TestResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"projects\":[");
    for (titles, 0..) |title, i| try body.print(testing.allocator, "{s}{{\"title\":\"{s}\"}}", .{ if (i > 0) "," else "", title });
    try body.appendSlice(testing.allocator, "]}");
    return t.request(.{ .method = .POST, .target = "/api/v1/projects/import", .headers = &.{ tenant(slug), auth, json_body }, .body = body.items });
}

fn idOf(rows: []const Project, title: []const u8) []const u8 {
    for (rows) |p| if (std.mem.eql(u8, p.title, title)) return p.id;
    return "";
}

test "imports idempotently: a title the workspace has is skipped, and every row comes back" {
    const t = try boot();
    defer t.deinit();
    const Rows = struct { projects: []const Project };
    var first = try import(t, "acme", &.{ "Anvil", "Magnet" });
    defer first.deinit();
    try testing.expectEqual(.ok, first.status);
    var again = try import(t, "acme", &.{ "Magnet", "Tornado seeds" });
    defer again.deinit();
    try testing.expectEqualStrings(idOf((try first.json(Rows)).projects, "Magnet"), idOf((try again.json(Rows)).projects, "Magnet"));

    var acme = try t.request(.{ .target = "/api/v1/projects", .headers = &.{ tenant("acme"), auth } });
    defer acme.deinit();
    const rows = (try acme.json(List)).projects;
    try testing.expectEqual(3, rows.len);
    var magnets: usize = 0;
    for (rows) |p| magnets += @intFromBool(std.mem.eql(u8, p.title, "Magnet"));
    try testing.expectEqual(1, magnets);

    // Another workspace may use the same titles.
    var globex = try import(t, "globex", &.{"Anvil"});
    defer globex.deinit();
    try testing.expectEqualStrings("tenant-globex", (try globex.json(Rows)).projects[0].workspaceId);
}

test "an invalid project is 422 with field errors" {
    const t = try boot();
    defer t.deinit();
    var res = try t.request(.{ .method = .POST, .target = "/api/v1/projects", .headers = &.{ tenant("acme"), auth, json_body }, .body = "{\"title\":\"\"}" });
    defer res.deinit();
    try testing.expectEqual(.unprocessable_entity, res.status);
    const body = try res.json(struct { errors: []const kzig.FieldError });
    try testing.expectEqualStrings("title", body.errors[0].field);
}
