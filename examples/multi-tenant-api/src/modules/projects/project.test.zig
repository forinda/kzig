const std = @import("std");
const kzig = @import("kzig");
const App = @import("../../main.zig").App;

const testing = std.testing;
const Header = kzig.Header;

fn get(headers: []const Header) !kzig.testing.TestResponse {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();
    return kzig.testing.request(testing.allocator, app, .{ .target = "/api/v1/projects", .headers = headers });
}

const all_tenants: Header = .{ .name = "authorization", .value = "Bearer token-all" };
const acme_only: Header = .{ .name = "authorization", .value = "Bearer token-acme" };

fn tenant(slug: []const u8) Header {
    return .{ .name = "x-tenant", .value = slug };
}

test "rejects requests without a token" {
    var res = try get(&.{tenant("acme")});
    defer res.deinit();
    try testing.expectEqual(.unauthorized, res.status);
}

test "answers 404 for an unknown tenant" {
    var res = try get(&.{ tenant("nope"), all_tenants });
    defer res.deinit();
    try testing.expectEqual(.not_found, res.status);
}

test "answers a tenant the user does not belong to like an unknown one (404, no enumeration)" {
    var ok = try get(&.{ tenant("acme"), acme_only });
    defer ok.deinit();
    try testing.expectEqual(.ok, ok.status);
    var other = try get(&.{ tenant("globex"), acme_only });
    defer other.deinit();
    try testing.expectEqual(.not_found, other.status);
}

test "keeps each tenant's projects apart" {
    const Body = struct { tenant: []const u8, projects: []const struct { title: []const u8, workspaceId: []const u8 } };
    var acme = try get(&.{ tenant("acme"), all_tenants });
    defer acme.deinit();
    const a = try acme.json(Body);
    try testing.expectEqualStrings("Acme Corp", a.tenant);
    try testing.expectEqual(1, a.projects.len);
    try testing.expectEqualStrings("Rocket skates", a.projects[0].title);
    try testing.expectEqualStrings("tenant-acme", a.projects[0].workspaceId);

    var globex = try get(&.{ tenant("globex"), all_tenants });
    defer globex.deinit();
    try testing.expectEqual(0, (try globex.json(Body)).projects.len);
}

test "the tenant falls back to the host's subdomain" {
    var res = try get(&.{ .{ .name = "host", .value = "acme.example.com" }, all_tenants });
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
}
