//! KickJS's `@forinda/kickjs-ws`: gateways listed in a module's `.gateways`,
//! JSON frames `{ "event": …, "data": … }`, rooms, heartbeat and drain.
//! Engine-neutral: a runtime upgrades the request, hands its connection in as
//! a `Conn`, and passes messages to the App (`wsOpen`, `wsMessage`, `wsPong`,
//! `wsClose`).
//!
//! ```zig
//! pub const ChatGateway = struct {
//!     pub const path = "/chat"; // ws://host/ws/chat
//!     pub const State = struct { name: []const u8 = "" };
//!     const Ctx = kzig.ws.Ctx(State);
//!     pub const events = .{
//!         .{ .event = "message:send", .handler = "send" },
//!         .{ .event = "*", .handler = "unknown" },
//!     };
//!     pub fn connect(self: *ChatGateway, ctx: *Ctx) !void { … }
//!     pub fn send(self: *ChatGateway, ctx: *Ctx, data: Message) !void { … }
//! };
//! ```
const std = @import("std");
const builtin = @import("builtin");
const context = @import("../core/context.zig");
const decode = @import("../core/decode.zig");
const uuid = @import("../upload/multipart.zig").uuid;

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// App spec `.ws`; KickJS's `WsAdapter` options.
pub const Options = struct {
    /// Gateways mount under it: `/ws` + the gateway's `path`.
    path: []const u8 = "/ws",
    /// Ping every socket this often; one that missed the previous pong is
    /// dropped. 0 disables.
    heartbeat_ms: u32 = 30_000,
    /// A larger message closes the socket with 1009.
    max_payload: usize = 64 * 1024,
    /// A socket whose client stops reading is cut once a write has waited
    /// this long, so it can't hold up broadcasts. 0 disables.
    write_timeout_ms: u32 = 10_000,
};

pub fn options(comptime spec: anytype) Options {
    var o: Options = .{};
    inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |f| {
        if (!@hasField(Options, f)) @compileError("ws: unknown option ." ++ f);
        @field(o, f) = @field(spec, f);
    }
    return o;
}

/// A runtime's connection. Calls may come from any thread.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (*anyopaque, []const u8) anyerror!void,
        ping: *const fn (*anyopaque) anyerror!void,
        /// Sends a close frame with `code` (0: none, just drop the socket).
        close: *const fn (*anyopaque, u16, []const u8) void,
    };
};

/// What the upgrade request carried, kept for the connection's lifetime.
pub const Upgrade = struct {
    path: []const u8,
    query: []const u8,
    headers: []const context.Header,
};

pub const Session = struct {
    id: [36]u8,
    gateway: usize,
    conn: Conn,
    /// Lives as long as the connection: state strings, the upgrade request.
    arena: std.heap.ArenaAllocator,
    /// Reset for every message.
    msg_arena: std.heap.ArenaAllocator,
    state: *anyopaque,
    upgrade: Upgrade,
    /// Room names, owned by the hub's allocator.
    rooms: std.ArrayList([]const u8) = .empty,
    /// `connect` let it in; until then broadcasts, pings and drain skip it.
    accepted: bool = false,
    alive: std.atomic.Value(bool) = .init(true),
    closed: std.atomic.Value(bool) = .init(false),

    fn send(s: *Session, frame: []const u8) void {
        if (s.closed.load(.acquire)) return;
        // A socket that can't take it is on its way out; its reader ends it.
        s.conn.vtable.send(s.conn.ptr, frame) catch {};
    }

    pub fn close(s: *Session, code: u16, reason: []const u8) void {
        if (s.closed.swap(true, .acq_rel)) return;
        s.conn.vtable.close(s.conn.ptr, code, reason);
    }

    fn inRoom(s: *const Session, room: []const u8) bool {
        for (s.rooms.items) |r| if (std.mem.eql(u8, r, room)) return true;
        return false;
    }
};

// ponytail: thread identity stands in for task identity, right while every
// task has its own thread (Io.Threaded); an evented Io needs a task-local.
/// Set while this thread holds a hub lock, so a hook that broadcasts while
/// the hub calls it (`draining`) doesn't lock it again.
threadlocal var holding = false;

// ponytail: one lock over every socket, held while a broadcast writes; a
// client that stops reading stalls the others until its write times out
// (`write_timeout_ms`). Per-socket send queues would remove the stall.
/// Every open socket of an App, its rooms, and the heartbeat.
pub const Hub = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    heartbeat: ?Io.Future(Io.Cancelable!void) = null,

    pub fn deinit(hub: *Hub) void {
        hub.stopHeartbeat();
        hub.sessions.deinit(hub.gpa);
    }

    fn lock(hub: *Hub) bool {
        if (holding) return false;
        hub.mutex.lockUncancelable(hub.io);
        holding = true;
        return true;
    }

    fn unlock(hub: *Hub, locked: bool) void {
        if (!locked) return;
        holding = false;
        hub.mutex.unlock(hub.io);
    }

    fn add(hub: *Hub, s: *Session) !void {
        const l = hub.lock();
        defer hub.unlock(l);
        try hub.sessions.append(hub.gpa, s);
    }

    fn remove(hub: *Hub, s: *Session) void {
        const l = hub.lock();
        defer hub.unlock(l);
        for (hub.sessions.items, 0..) |x, i| if (x == s) {
            _ = hub.sessions.swapRemove(i);
            return;
        };
    }

    /// To every socket in `room` (KickJS `ctx.to(room).send`).
    fn toRoom(hub: *Hub, room: []const u8, frame: []const u8) void {
        const l = hub.lock();
        defer hub.unlock(l);
        for (hub.sessions.items) |s| if (s.accepted and s.inRoom(room)) s.send(frame);
    }

    /// To the gateway's sockets, `except` one.
    fn toGateway(hub: *Hub, gateway: usize, except: ?*Session, frame: []const u8) void {
        const l = hub.lock();
        defer hub.unlock(l);
        for (hub.sessions.items) |s| if (s.accepted and s.gateway == gateway and s != except) s.send(frame);
    }

    pub fn startHeartbeat(hub: *Hub) void {
        if (hub.opts.heartbeat_ms == 0 or hub.heartbeat != null) return;
        hub.heartbeat = hub.io.concurrent(beat, .{hub}) catch null;
    }

    pub fn stopHeartbeat(hub: *Hub) void {
        if (hub.heartbeat) |*f| f.cancel(hub.io) catch {};
        hub.heartbeat = null;
    }

    fn beat(hub: *Hub) Io.Cancelable!void {
        while (true) {
            try hub.io.sleep(.fromMilliseconds(hub.opts.heartbeat_ms), .awake);
            const l = hub.lock();
            defer hub.unlock(l);
            for (hub.sessions.items) |s| {
                if (!s.accepted) continue;
                // Missed the last pong: drop it without a close frame.
                if (!s.alive.swap(false, .acq_rel)) {
                    s.close(0, "");
                    continue;
                }
                if (!s.closed.load(.acquire)) s.conn.vtable.ping(s.conn.ptr) catch {};
            }
        }
    }
};

/// What a gateway handler gets (KickJS `WsContext`); `State` is the
/// gateway's per-socket state.
pub fn Ctx(comptime State: type) type {
    return struct {
        const Self = @This();

        session: *Session,
        hub: *Hub,
        /// The socket's id, a UUID.
        id: []const u8,
        /// The event being handled; empty in `connect` and `disconnect`.
        event: []const u8 = "",
        /// Freed after this message (or hook).
        arena: Allocator,
        /// Freed when the socket closes: for what `state` keeps.
        conn_arena: Allocator,
        state: *State,
        /// In `draining`, which runs on another task than the socket's own:
        /// only `send` (and reading `state`).
        draining: bool = false,

        pub fn send(self: *Self, event: []const u8, data: anytype) !void {
            self.session.send(try frameOf(self.arena, event, data));
        }

        /// Closes the socket (`4401` before any handler, say).
        pub fn close(self: *Self, code: u16, reason: []const u8) void {
            self.session.close(code, reason);
        }

        pub fn join(self: *Self, room: []const u8) !void {
            if (self.draining) return error.Draining;
            const l = self.hub.lock();
            defer self.hub.unlock(l);
            if (self.session.inRoom(room)) return;
            const name = try self.hub.gpa.dupe(u8, room);
            errdefer self.hub.gpa.free(name);
            try self.session.rooms.append(self.hub.gpa, name);
        }

        pub fn leave(self: *Self, room: []const u8) void {
            if (self.draining) return;
            const l = self.hub.lock();
            defer self.hub.unlock(l);
            for (self.session.rooms.items, 0..) |r, i| if (std.mem.eql(u8, r, room)) {
                self.hub.gpa.free(self.session.rooms.swapRemove(i));
                return;
            };
        }

        /// The rooms this socket is in, copied into `arena`.
        pub fn rooms(self: *Self) ![]const []const u8 {
            const l = self.hub.lock();
            defer self.hub.unlock(l);
            const out = try self.arena.alloc([]const u8, self.session.rooms.items.len);
            for (self.session.rooms.items, out) |r, *o| o.* = try self.arena.dupe(u8, r);
            return out;
        }

        pub fn inRoom(self: *Self, room: []const u8) bool {
            const l = self.hub.lock();
            defer self.hub.unlock(l);
            return self.session.inRoom(room);
        }

        pub const Room = struct {
            ctx: *Self,
            name: []const u8,

            /// To every socket in the room, this one included.
            pub fn send(room: Room, event: []const u8, data: anytype) !void {
                room.ctx.hub.toRoom(room.name, try frameOf(room.ctx.arena, event, data));
            }
        };

        pub fn to(self: *Self, room: []const u8) Room {
            return .{ .ctx = self, .name = room };
        }

        /// To the gateway's other sockets.
        pub fn broadcast(self: *Self, event: []const u8, data: anytype) !void {
            self.hub.toGateway(self.session.gateway, self.session, try frameOf(self.arena, event, data));
        }

        /// To every socket of the gateway, this one included.
        pub fn broadcastAll(self: *Self, event: []const u8, data: anytype) !void {
            self.hub.toGateway(self.session.gateway, null, try frameOf(self.arena, event, data));
        }

        /// A header of the upgrade request.
        pub fn header(self: *const Self, name: []const u8) ?[]const u8 {
            for (self.session.upgrade.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }

        /// A query parameter of the upgrade request (`?token=`: browsers
        /// can't set WebSocket headers).
        pub fn query(self: *const Self, name: []const u8) !?[]const u8 {
            var it = std.mem.splitScalar(u8, self.session.upgrade.query, '&');
            while (it.next()) |pair| {
                const eq = std.mem.findScalar(u8, pair, '=') orelse pair.len;
                const key = context.percentDecode(self.arena, pair[0..eq], true) catch continue;
                if (!std.mem.eql(u8, key, name)) continue;
                return context.percentDecode(self.arena, if (eq < pair.len) pair[eq + 1 ..] else "", true) catch null;
            }
            return null;
        }
    };
}

fn frameOf(arena: Allocator, event: []const u8, data: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .event = event, .data = data }, .{});
}

pub fn StateOf(comptime G: type) type {
    return if (@hasDecl(G, "State")) G.State else struct {};
}

/// The full path of each gateway, checked at comptime.
pub fn paths(comptime gateways: []const type, comptime opts: Options) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (gateways) |G| {
            if (!@hasDecl(G, "path")) @compileError(@typeName(G) ++ ": a gateway needs `pub const path`");
            const p: []const u8 = G.path;
            if (p.len == 0 or p[0] != '/') @compileError(@typeName(G) ++ ".path must start with '/'");
            const full = std.mem.trimEnd(u8, opts.path ++ (if (std.mem.eql(u8, p, "/")) "" else p), "/");
            for (out) |o| if (std.mem.eql(u8, o, full)) @compileError("two gateways at " ++ full);
            if (@hasDecl(G, "events")) for (G.events) |e| {
                const h: []const u8 = e.handler;
                if (!@hasDecl(G, h)) @compileError(@typeName(G) ++ " has no handler " ++ h ++ " for event " ++ e.event);
            };
            out = out ++ .{full};
        }
        const result = out;
        return result;
    }
}

/// The gateway at `path`, if any.
pub fn route(comptime full_paths: []const []const u8, path: []const u8) ?usize {
    const p = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    inline for (full_paths, 0..) |f, i| if (std.mem.eql(u8, f, p)) return i;
    return null;
}

/// Opens a socket on gateway `G`: state, then `connect`. Null when `connect`
/// closed it (the runtime ends the connection).
pub fn open(comptime G: type, gateway: *G, hub: *Hub, index: usize, conn: Conn, upgrade: Upgrade) !?*Session {
    const s = try hub.gpa.create(Session);
    s.* = .{
        .id = uuid(hub.io),
        .gateway = index,
        .conn = conn,
        .arena = .init(hub.gpa),
        .msg_arena = .init(hub.gpa),
        .state = undefined,
        .upgrade = undefined,
    };
    errdefer free(hub, s);
    const a = s.arena.allocator();
    const headers = try a.alloc(context.Header, upgrade.headers.len);
    for (upgrade.headers, headers) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    s.upgrade = .{ .path = try a.dupe(u8, upgrade.path), .query = try a.dupe(u8, upgrade.query), .headers = headers };
    const state = try a.create(StateOf(G));
    state.* = .{};
    s.state = state;
    try hub.add(s);
    if (@hasDecl(G, "connect")) {
        var ctx = ctxOf(G, hub, s);
        report(G, "connect", gateway.connect(&ctx));
    }
    // Refused: `disconnect` still runs, for whatever `connect` set up.
    if (s.closed.load(.acquire)) {
        close(G, gateway, hub, s);
        return null;
    }
    const l = hub.lock();
    defer hub.unlock(l);
    s.accepted = true;
    return s;
}

/// One text message: `{ "event", "data" }` to the handler for `event`, else
/// `"*"`. Bad frames are answered with an `error` event.
pub fn message(comptime G: type, gateway: *G, hub: *Hub, s: *Session, text: []const u8) void {
    _ = s.msg_arena.reset(.retain_capacity);
    var ctx = ctxOf(G, hub, s);
    const a = ctx.arena;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch
        return ctx.send("error", .{ .message = "Invalid JSON" }) catch {};
    const event = switch (parsed) {
        .object => |o| if (o.get("event")) |e| switch (e) {
            .string => |str| str,
            else => null,
        } else null,
        else => null,
    } orelse return ctx.send("error", .{ .message = "Invalid message format: missing \"event\" field" }) catch {};
    ctx.event = event;
    const data = parsed.object.get("data") orelse .null;
    if (!@hasDecl(G, "events")) return;
    inline for (G.events) |e| {
        if (comptime !std.mem.eql(u8, e.event, "*")) if (std.mem.eql(u8, e.event, event)) return call(G, e.handler, gateway, &ctx, data);
    }
    inline for (G.events) |e| {
        if (comptime std.mem.eql(u8, e.event, "*")) return call(G, e.handler, gateway, &ctx, data);
    }
}

pub fn pong(s: *Session) void {
    s.alive.store(true, .release);
}

/// The socket is gone: `disconnect` (its rooms still readable), then free.
pub fn close(comptime G: type, gateway: *G, hub: *Hub, s: *Session) void {
    if (@hasDecl(G, "disconnect")) {
        _ = s.msg_arena.reset(.retain_capacity);
        var ctx = ctxOf(G, hub, s);
        report(G, "disconnect", gateway.disconnect(&ctx));
    }
    hub.remove(s);
    free(hub, s);
}

/// Shutdown: `draining` for every socket of `G`, then close 1001.
pub fn drain(comptime G: type, gateway: *G, hub: *Hub, index: usize) void {
    const l = hub.lock();
    defer hub.unlock(l);
    for (hub.sessions.items) |s| {
        if (s.gateway != index or !s.accepted) continue;
        if (@hasDecl(G, "draining")) {
            // Not the socket's arenas: its task may be handling a message.
            var tmp: std.heap.ArenaAllocator = .init(hub.gpa);
            defer tmp.deinit();
            var ctx = ctxOf(G, hub, s);
            ctx.arena = tmp.allocator();
            ctx.conn_arena = tmp.allocator();
            ctx.draining = true;
            report(G, "draining", gateway.draining(&ctx));
        }
        s.close(1001, "Server shutting down");
    }
}

fn free(hub: *Hub, s: *Session) void {
    for (s.rooms.items) |r| hub.gpa.free(r);
    s.rooms.deinit(hub.gpa);
    s.arena.deinit();
    s.msg_arena.deinit();
    hub.gpa.destroy(s);
}

fn ctxOf(comptime G: type, hub: *Hub, s: *Session) Ctx(StateOf(G)) {
    return .{
        .session = s,
        .hub = hub,
        .id = &s.id,
        .arena = s.msg_arena.allocator(),
        .conn_arena = s.arena.allocator(),
        .state = @ptrCast(@alignCast(s.state)),
    };
}

/// `data` decoded as the handler's third parameter (like a body: issues are
/// an `error` event); `std.json.Value` is passed as it is.
fn call(comptime G: type, comptime handler: []const u8, gateway: *G, ctx: *Ctx(StateOf(G)), data: std.json.Value) void {
    const f = @field(G, handler);
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    const result = switch (params.len) {
        2 => f(gateway, ctx),
        3 => blk: {
            const T = params[2].?;
            if (T == std.json.Value) break :blk f(gateway, ctx, data);
            var issues: decode.Issues = .init(ctx.arena);
            const value = (decode.json(T, ctx.arena, data, &issues) catch return) orelse
                return ctx.send("error", .{ .message = "Invalid data", .errors = issues.list.items }) catch {};
            break :blk f(gateway, ctx, value);
        },
        else => @compileError(@typeName(G) ++ "." ++ handler ++ " must be fn (self, *Ctx) or fn (self, *Ctx, data)"),
    };
    report(G, handler, result);
}

/// KickJS logs a handler's error and keeps the socket.
fn report(comptime G: type, comptime handler: []const u8, result: anytype) void {
    if (@typeInfo(@TypeOf(result)) != .error_union) return;
    result catch |err| if (!builtin.is_test) std.log.err("ws {s}.{s}: {t}", .{ @typeName(G), handler, err });
}
