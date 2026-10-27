const std = @import("std");
const kzig = @import("kzig");

/// Who is in which room, as (room, socket id, name). A user with two tabs
/// is listed once. In this process only: ws-chat shares it through Redis.
pub const Presence = struct {
    process: *const kzig.Process,
    mutex: std.Io.Mutex = .init,
    // ponytail: a list scanned per call; a map per room if rooms get big.
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { room: []const u8, socket: []const u8, name: []const u8 };

    pub fn deinit(self: *Presence) void {
        for (self.entries.items) |e| self.free(e);
        self.entries.deinit(self.process.gpa);
    }

    pub fn add(self: *Presence, room: []const u8, socket: []const u8, name: []const u8) !void {
        const gpa = self.process.gpa;
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        for (self.entries.items) |e| if (std.mem.eql(u8, e.room, room) and std.mem.eql(u8, e.socket, socket)) return;
        const r = try gpa.dupe(u8, room);
        errdefer gpa.free(r);
        const id = try gpa.dupe(u8, socket);
        errdefer gpa.free(id);
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        try self.entries.append(gpa, .{ .room = r, .socket = id, .name = n });
    }

    pub fn remove(self: *Presence, room: []const u8, socket: []const u8) void {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.room, room) and std.mem.eql(u8, e.socket, socket)) {
            self.free(self.entries.swapRemove(i));
            return;
        };
    }

    /// Sorted, each name once.
    pub fn users(self: *Presence, arena: std.mem.Allocator, room: []const u8) ![]const []const u8 {
        self.mutex.lockUncancelable(self.process.io);
        defer self.mutex.unlock(self.process.io);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.room, room)) continue;
            for (out.items) |n| {
                if (std.mem.eql(u8, n, e.name)) break;
            } else try out.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, out.items, {}, lessThan);
        return out.items;
    }

    fn free(self: *Presence, e: Entry) void {
        self.process.gpa.free(e.room);
        self.process.gpa.free(e.socket);
        self.process.gpa.free(e.name);
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
