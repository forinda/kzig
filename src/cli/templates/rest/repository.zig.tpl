const std = @import("std");
const kzig = @import("kzig");
const constants = @import("{{kebab}}.constants.zig");

pub const {{Pascal}} = struct {
    id: u64,
    name: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const Create{{Pascal}} = struct {
    name: []const u8,

    pub fn validate(self: *const Create{{Pascal}}, issues: *kzig.Issues) !void {
        try checkName(self.name, issues);
    }
};

pub const Update{{Pascal}} = struct {
    name: ?[]const u8 = null,

    pub fn validate(self: *const Update{{Pascal}}, issues: *kzig.Issues) !void {
        if (self.name) |name| try checkName(name, issues);
    }
};

fn checkName(name: []const u8, issues: *kzig.Issues) !void {
    if (name.len == 0 or name.len > 200) try issues.add("name", "must be 1 to 200 characters");
}

pub const {{Pascal}}Page = struct { rows: []const {{Pascal}}, total: usize };

/// In memory — replace with your database. Shared by concurrent requests,
/// so every access holds the lock.
pub const {{Pascal}}Repository = struct {
    process: *const kzig.Process,
    mutex: std.Io.Mutex = .init,
    rows: std.ArrayList({{Pascal}}) = .empty,
    /// Owns the rows' strings until deinit (an edit keeps the old one).
    strings: std.heap.ArenaAllocator = undefined,
    next_id: u64 = 1,

    pub fn init(self: *{{Pascal}}Repository) void {
        self.strings = .init(self.process.gpa);
    }

    pub fn deinit(self: *{{Pascal}}Repository) void {
        self.rows.deinit(self.process.gpa);
        self.strings.deinit();
    }

    pub fn findAll(self: *{{Pascal}}Repository, arena: std.mem.Allocator, query: constants.Query) !{{Pascal}}Page {
        self.lock();
        defer self.unlock();
        var matched: std.ArrayList({{Pascal}}) = .empty;
        for (self.rows.items) |row| if (matches(row, query)) try matched.append(arena, row);
        std.mem.sort({{Pascal}}, matched.items, query.sort, lessThan);
        const start = @min(query.offset, matched.items.len);
        const end = @min(start + query.limit, matched.items.len);
        return .{ .rows = matched.items[start..end], .total = matched.items.len };
    }

    pub fn findById(self: *{{Pascal}}Repository, id: u64) ?{{Pascal}} {
        self.lock();
        defer self.unlock();
        for (self.rows.items) |row| if (row.id == id) return row;
        return null;
    }

    pub fn create(self: *{{Pascal}}Repository, input: Create{{Pascal}}) !{{Pascal}} {
        self.lock();
        defer self.unlock();
        const now = self.nowMs();
        const row: {{Pascal}} = .{
            .id = self.next_id,
            .name = try self.strings.allocator().dupe(u8, input.name),
            .created_at = now,
            .updated_at = now,
        };
        try self.rows.append(self.process.gpa, row);
        self.next_id += 1;
        return row;
    }

    pub fn update(self: *{{Pascal}}Repository, id: u64, input: Update{{Pascal}}) !?{{Pascal}} {
        self.lock();
        defer self.unlock();
        for (self.rows.items) |*row| if (row.id == id) {
            if (input.name) |name| row.name = try self.strings.allocator().dupe(u8, name);
            row.updated_at = self.nowMs();
            return row.*;
        };
        return null;
    }

    pub fn delete(self: *{{Pascal}}Repository, id: u64) bool {
        self.lock();
        defer self.unlock();
        for (self.rows.items, 0..) |row, i| if (row.id == id) {
            _ = self.rows.orderedRemove(i);
            return true;
        };
        return false;
    }

    fn lock(self: *{{Pascal}}Repository) void {
        self.mutex.lockUncancelable(self.process.io);
    }

    fn unlock(self: *{{Pascal}}Repository) void {
        self.mutex.unlock(self.process.io);
    }

    fn nowMs(self: *{{Pascal}}Repository) i64 {
        const ns = std.Io.Clock.real.now(self.process.io).toNanoseconds();
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }
};

fn matches(row: {{Pascal}}, query: constants.Query) bool {
    // `name` is the only filterable field, with the operators checkFilters allows.
    for (query.filters) |f| {
        const ok = switch (f.operator) {
            .eq => std.mem.eql(u8, row.name, f.value),
            .neq => !std.mem.eql(u8, row.name, f.value),
            .contains => std.ascii.findIgnoreCase(row.name, f.value) != null,
            .starts => std.ascii.startsWithIgnoreCase(row.name, f.value),
            .ends => std.ascii.endsWithIgnoreCase(row.name, f.value),
            else => false,
        };
        if (!ok) return false;
    }
    return query.search.len == 0 or std.ascii.findIgnoreCase(row.name, query.search) != null;
}

fn lessThan(sort: []const kzig.Sort, a: {{Pascal}}, b: {{Pascal}}) bool {
    for (sort) |s| {
        const order = if (std.mem.eql(u8, s.field, "name"))
            std.mem.order(u8, a.name, b.name)
        else
            std.math.order(a.created_at, b.created_at);
        if (order != .eq) return if (s.direction == .asc) order == .lt else order == .gt;
    }
    return a.id < b.id;
}
