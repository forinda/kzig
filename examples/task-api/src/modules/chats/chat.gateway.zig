const std = @import("std");
const kzig = @import("kzig");
const auth = @import("chat.auth.zig");
const Presence = @import("presence.repository.zig").Presence;
const Clock = @import("../../clock.zig").Clock;
const iso = @import("../../clock.zig").iso;

/// `[a-z0-9-]{1,32}`.
pub fn isRoom(room: []const u8) bool {
    if (room.len == 0 or room.len > 32) return false;
    for (room) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

const RoomMessage = struct {
    room: []const u8,

    pub fn validate(self: *const RoomMessage, issues: *kzig.Issues) !void {
        if (!isRoom(self.room)) try issues.add("room", "must match [a-z0-9-]{1,32}");
    }
};

const ChatMessage = struct {
    room: []const u8,
    text: []const u8,

    pub fn validate(self: *const ChatMessage, issues: *kzig.Issues) !void {
        if (!isRoom(self.room)) try issues.add("room", "must match [a-z0-9-]{1,32}");
        const text = std.mem.trim(u8, self.text, " \t\r\n");
        if (text.len == 0 or text.len > 500) try issues.add("text", "must be 1 to 500 characters");
    }
};

/// `ws://host/ws/chat?token=…`. `connect` refuses a socket without a valid
/// token (4401) before any of the handlers run.
///
/// Client → server: `room:join {room}`, `room:leave {room}`,
/// `message:send {room, text}`. Server → client: `welcome`,
/// `room:users {room, users}`, `message {room, from, text, at}`, `error {message}`,
/// `server:draining`.
pub const ChatGateway = struct {
    auth: *auth.ChatAuth,
    presence: *Presence,
    clock: *Clock,

    pub const path = "/chat";
    pub const State = struct { name: []const u8 = "" };
    const Ctx = kzig.ws.Ctx(State);

    pub const events = .{
        .{ .event = "room:join", .handler = "join" },
        .{ .event = "room:leave", .handler = "leave" },
        .{ .event = "message:send", .handler = "send" },
        .{ .event = "*", .handler = "unknown" },
    };

    /// `?token=` (browsers can't set WebSocket headers) or `Authorization: Bearer`.
    pub fn connect(self: *ChatGateway, ctx: *Ctx) !void {
        const token = try ctx.query("token") orelse auth.bearer(ctx.header("authorization")) orelse
            return ctx.close(4401, "Unauthorized");
        const user = try self.auth.verify(ctx.arena, token) orelse return ctx.close(4401, "Unauthorized");
        ctx.state.name = try ctx.conn_arena.dupe(u8, user.name);
        try ctx.send("welcome", .{ .id = ctx.id, .name = ctx.state.name });
    }

    pub fn join(self: *ChatGateway, ctx: *Ctx, data: RoomMessage) !void {
        try ctx.join(try channel(ctx.arena, data.room));
        try self.presence.add(data.room, ctx.id, ctx.state.name);
        try self.announce(ctx, data.room);
    }

    pub fn leave(self: *ChatGateway, ctx: *Ctx, data: RoomMessage) !void {
        const ch = try channel(ctx.arena, data.room);
        if (!ctx.inRoom(ch)) return;
        ctx.leave(ch);
        self.presence.remove(data.room, ctx.id);
        try self.announce(ctx, data.room);
        try ctx.send("room:users", .{ .room = data.room, .users = &[_][]const u8{} });
    }

    /// Only to rooms this socket joined.
    pub fn send(self: *ChatGateway, ctx: *Ctx, data: ChatMessage) !void {
        const ch = try channel(ctx.arena, data.room);
        if (!ctx.inRoom(ch))
            return ctx.send("error", .{ .message = try ctx.arena.print("join {s} before sending to it", .{data.room}) });
        try ctx.to(ch).send("message", .{
            .room = data.room,
            .from = ctx.state.name,
            .text = std.mem.trim(u8, data.text, " \t\r\n"),
            .at = try iso(ctx.arena, self.clock.now()),
        });
    }

    pub fn unknown(_: *ChatGateway, ctx: *Ctx, _: std.json.Value) !void {
        try ctx.send("error", .{ .message = try ctx.arena.print("unknown event: {s}", .{ctx.event}) });
    }

    /// Everyone left in the socket's rooms gets the new list.
    pub fn disconnect(self: *ChatGateway, ctx: *Ctx) !void {
        for (try ctx.rooms()) |r| if (std.mem.startsWith(u8, r, "room:")) {
            self.presence.remove(r["room:".len..], ctx.id);
            try self.announce(ctx, r["room:".len..]);
        };
    }

    /// Shutting down: this instance's clients reconnect elsewhere.
    pub fn draining(_: *ChatGateway, ctx: *Ctx) !void {
        try ctx.send("server:draining", .{});
    }

    fn announce(self: *ChatGateway, ctx: *Ctx, room: []const u8) !void {
        try ctx.to(try channel(ctx.arena, room)).send("room:users", .{ .room = room, .users = try self.presence.users(ctx.arena, room) });
    }
};

/// Prefixed: room names are global, so a chat room can't collide with others.
fn channel(arena: std.mem.Allocator, room: []const u8) ![]const u8 {
    return arena.print("room:{s}", .{room});
}
