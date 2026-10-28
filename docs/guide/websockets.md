# WebSockets

KickJS's `@forinda/kickjs-ws`: a gateway in a module's `.gateways`, at `/ws` + its `path`.
Frames are JSON `{ "event": …, "data": … }`; a handler's `data` is decoded like a request body.

```zig
pub const ChatGateway = struct {
    presence: *Presence, // injected like any service

    pub const path = "/chat"; // ws://host/ws/chat
    pub const State = struct { name: []const u8 = "" }; // per socket
    const Ctx = kzig.ws.Ctx(State);
    pub const events = .{
        .{ .event = "message:send", .handler = "send" },
        .{ .event = "*", .handler = "unknown" },
    };

    pub fn connect(self: *ChatGateway, ctx: *Ctx) !void {
        const user = try self.verify(try ctx.query("token")) orelse return ctx.close(4401, "Unauthorized");
        ctx.state.name = try ctx.conn_arena.dupe(u8, user.name);
    }

    pub fn send(_: *ChatGateway, ctx: *Ctx, data: struct { room: []const u8, text: []const u8 }) !void {
        if (!ctx.inRoom(data.room)) return ctx.send("error", .{ .message = "join it first" });
        try ctx.to(data.room).send("message", .{ .from = ctx.state.name, .text = data.text });
    }
};
```

`ws.Ctx` has `send`, `close`, `join`, `leave`, `rooms`, `to(room).send`, `broadcast`,
`broadcastAll`, and the upgrade request's `header` and `query`. Optional hooks: `connect`,
`disconnect`, `draining` (on shutdown, before every socket closes with 1001). The App's
`.ws = .{ .path, .heartbeat_ms, .max_payload, .write_timeout_ms }` sets the mount, the ping
interval (a socket that misses a pong is dropped), the message limit (1009 over it) and how long
a write may wait on a client that stopped reading before its socket is cut. Both runtimes serve
gateways with the same loop (http.zig hands the socket over after the handshake).
task-api's `chat` module is the archive's ws-chat without Redis.
