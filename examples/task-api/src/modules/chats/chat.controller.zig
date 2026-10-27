const std = @import("std");
const kzig = @import("kzig");
const auth = @import("chat.auth.zig");
const Presence = @import("presence.repository.zig").Presence;
const isRoom = @import("chat.gateway.zig").isRoom;

const TokenBody = struct {
    name: []const u8,

    /// `[\w-]{1,24}` once trimmed.
    pub fn validate(self: *const TokenBody, issues: *kzig.Issues) !void {
        const name = std.mem.trim(u8, self.name, " \t");
        const ok = name.len > 0 and name.len <= 24 and for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break false;
        } else true;
        if (!ok) try issues.add("name", "must match [\\w-]{1,24}");
    }
};

const RoomParams = struct {
    room: []const u8,

    pub fn validate(self: *const RoomParams, issues: *kzig.Issues) !void {
        if (!isRoom(self.room)) try issues.add("room", "must match [a-z0-9-]{1,32}");
    }
};

pub const ChatController = struct {
    auth: *auth.ChatAuth,
    presence: *Presence,

    pub const docs = .{ .tags = &[_][]const u8{"Chat"} };

    pub const routes = .{
        .{ .method = .POST, .path = "/token", .handler = "token", .docs = .{
            .summary = "A chat token for a display name (demo sign-in)",
            .responses = .{.{ .status = 201, .description = "Issued", .body = struct { token: []const u8 } }},
        } },
        .{ .method = .GET, .path = "/rooms/:room/users", .handler = "users", .docs = .{ .summary = "Who is in a room", .bearer_auth = true } },
    };

    /// Demo sign-in: swap for your real auth.
    pub fn token(self: *ChatController, ctx: *kzig.Ctx, got: struct { body: TokenBody }) !void {
        const name = std.mem.trim(u8, got.body.name, " \t");
        try ctx.created(.{ .token = try self.auth.issue(ctx.arena, name, auth.ChatAuth.ttl_s) });
    }

    /// The same token as the socket: anyone could otherwise watch a room unseen.
    pub fn users(self: *ChatController, ctx: *kzig.Ctx, got: struct { params: RoomParams }) !struct { room: []const u8, users: []const []const u8 } {
        const t = auth.bearer(ctx.header("authorization")) orelse return ctx.fail(.unauthorized, "Bearer chat token required");
        _ = try self.auth.verify(ctx.arena, t) orelse return ctx.fail(.unauthorized, "Bearer chat token required");
        return .{ .room = got.params.room, .users = try self.presence.users(ctx.arena, got.params.room) };
    }
};
