//! ws-chat's `chat.test.ts`: the same protocol over a real socket.
const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");
const ChatAuth = @import("chat.auth.zig").ChatAuth;

const testing = std.testing;

fn token(live: *test_app.Live, name: []const u8, ttl_s: i64) ![]const u8 {
    return live.t.app.get(ChatAuth).issue(testing.allocator, name, ttl_s);
}

fn connect(live: *test_app.Live, name: []const u8) !*kzig.testing.WsClient {
    const t = try token(live, name, 3600);
    defer testing.allocator.free(t);
    const target = try std.fmt.allocPrint(testing.allocator, "/ws/chat?token={s}", .{t});
    defer testing.allocator.free(target);
    return live.client(target);
}

test "chat: refuses a socket without a valid token (close 4401)" {
    const live = try test_app.listen(&.{}, null);
    defer live.stop();
    const expired = try token(live, "eve", -1);
    defer testing.allocator.free(expired);
    const expired_target = try std.fmt.allocPrint(testing.allocator, "/ws/chat?token={s}", .{expired});
    defer testing.allocator.free(expired_target);
    for ([_][]const u8{ "/ws/chat", "/ws/chat?token=forged.token", expired_target }) |target| {
        const c = try live.client(target);
        defer c.deinit();
        try testing.expectEqual(@as(?u16, 4401), try c.closeCode());
    }
}

test "chat: delivers a room message from one client to another, with the room user list" {
    const live = try test_app.listen(&.{}, null);
    defer live.stop();
    const alice = try connect(live, "alice");
    defer alice.deinit();
    const bob = try connect(live, "bob");
    defer bob.deinit();
    try testing.expect(std.mem.find(u8, try alice.expect("welcome"), "\"name\":\"alice\"") != null);

    try alice.emit("room:join", .{ .room = "general" });
    try testing.expect(std.mem.find(u8, try alice.expect("room:users"), "[\"alice\"]") != null);
    try bob.emit("room:join", .{ .room = "general" });
    try testing.expectEqualStrings(
        "{\"event\":\"room:users\",\"data\":{\"room\":\"general\",\"users\":[\"alice\",\"bob\"]}}",
        try alice.expect("room:users"),
    );

    try alice.emit("message:send", .{ .room = "general", .text = "hi bob" });
    const message = try bob.expect("message");
    try testing.expect(std.mem.find(u8, message, "\"room\":\"general\",\"from\":\"alice\",\"text\":\"hi bob\"") != null);

    // Same list over HTTP.
    var anon = try live.t.get("/api/v1/chat/rooms/general/users");
    defer anon.deinit();
    try testing.expectEqual(.unauthorized, anon.status);
    const carol = try token(live, "carol", 3600);
    defer testing.allocator.free(carol);
    const bearer = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{carol});
    defer testing.allocator.free(bearer);
    var users = try live.t.request(.{ .target = "/api/v1/chat/rooms/general/users", .headers = &.{.{ .name = "authorization", .value = bearer }} });
    defer users.deinit();
    try testing.expectEqual(.ok, users.status);
    try testing.expectEqualStrings("{\"room\":\"general\",\"users\":[\"alice\",\"bob\"]}", users.body);

    // Leaving (or disconnecting) updates everyone else's list.
    try bob.sendFrame(8, "\x03\xe8");
    try testing.expectEqualStrings(
        "{\"event\":\"room:users\",\"data\":{\"room\":\"general\",\"users\":[\"alice\"]}}",
        try alice.expect("room:users"),
    );
}

test "chat: keeps rooms isolated and refuses sending to a room you have not joined" {
    const live = try test_app.listen(&.{}, null);
    defer live.stop();
    const a = try connect(live, "ann");
    defer a.deinit();
    const b = try connect(live, "ben");
    defer b.deinit();
    try a.emit("room:join", .{ .room = "red" });
    try b.emit("room:join", .{ .room = "blue" });
    _ = try a.expect("room:users");
    _ = try b.expect("room:users");

    try a.emit("message:send", .{ .room = "red", .text = "red only" });
    // The sender is in the room too.
    try testing.expect(std.mem.find(u8, try a.expect("message"), "red only") != null);
    try a.emit("message:send", .{ .room = "blue", .text = "sneaky" });
    try testing.expectEqualStrings("{\"event\":\"error\",\"data\":{\"message\":\"join blue before sending to it\"}}", try a.expect("error"));

    // b's next frame is its own room's, not red's or the sneaky one.
    try b.emit("message:send", .{ .room = "blue", .text = "blue only" });
    try testing.expect(std.mem.find(u8, try b.expect("message"), "blue only") != null);
}

test "chat: pings on the heartbeat interval" {
    const live = try test_app.listen(&.{}, 100);
    defer live.stop();
    const c = try connect(live, "carol");
    defer c.deinit();
    while ((try c.next()).op != 9) {}
}

test "chat: issues tokens only for valid names" {
    const t = try test_app.boot(&.{});
    defer t.deinit();
    const json: kzig.Header = .{ .name = "content-type", .value = "application/json" };
    var bad = try t.request(.{ .method = .POST, .target = "/api/v1/chat/token", .headers = &.{json}, .body = "{\"name\":\"x y\"}" });
    defer bad.deinit();
    try testing.expectEqual(.unprocessable_entity, bad.status);
    var ok = try t.request(.{ .method = .POST, .target = "/api/v1/chat/token", .headers = &.{json}, .body = "{\"name\":\"dana\"}" });
    defer ok.deinit();
    try testing.expectEqual(.created, ok.status);
    try testing.expect(std.mem.findScalar(u8, (try ok.json(struct { token: []const u8 })).token, '.') != null);
}

test "chat: on shutdown, tells this instance's clients to reconnect before their sockets close" {
    const live = try test_app.listen(&.{}, null);
    const c = try connect(live, "erin");
    defer c.deinit();
    _ = try c.expect("welcome");
    live.stop();
    // A socket's frames arrive in order: the notice came before the close.
    _ = try c.expect("server:draining");
    try testing.expectEqual(@as(?u16, 1001), try c.closeCode());
}
