//! KickJS's `@forinda/kickjs-storage`: one `Storage` over memory, a disk
//! folder or an S3 bucket (`storage/s3.zig`). Whole bodies, not streams.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const PutOptions = struct { content_type: ?[]const u8 = null };

pub const FileInfo = struct {
    key: []const u8,
    size: u64,
    /// Unix seconds.
    last_modified: i64,
    /// Disk keeps none.
    content_type: ?[]const u8 = null,
};

pub const ListOptions = struct {
    prefix: []const u8 = "",
    /// The last key of the previous page.
    cursor: ?[]const u8 = null,
    limit: u32 = 1000,
};

pub const ListPage = struct {
    files: []const FileInfo,
    /// Pass it back for the next page; null on the last.
    cursor: ?[]const u8 = null,
};

pub const UrlOptions = struct {
    /// 1 s to 7 days (S3's limit for a presigned URL).
    expires_in: u32 = 3600,
};

pub const Error = error{ InvalidKey, InvalidLimit };

/// A storage driver. Results are allocated in the allocator passed.
pub const Storage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (*anyopaque, []const u8, []const u8, PutOptions) anyerror!void,
        get: *const fn (*anyopaque, Allocator, []const u8) anyerror!?[]u8,
        stat: *const fn (*anyopaque, Allocator, []const u8) anyerror!?FileInfo,
        delete: *const fn (*anyopaque, []const u8) anyerror!void,
        list: *const fn (*anyopaque, Allocator, ListOptions) anyerror!ListPage,
        url: *const fn (*anyopaque, Allocator, []const u8, UrlOptions) anyerror![]const u8,
    };

    pub fn put(s: Storage, key: []const u8, data: []const u8, options: PutOptions) !void {
        return s.vtable.put(s.ptr, try checkKey(key), data, options);
    }

    /// The file's bytes, or null when there is none.
    pub fn get(s: Storage, a: Allocator, key: []const u8) !?[]u8 {
        return s.vtable.get(s.ptr, a, try checkKey(key));
    }

    pub fn stat(s: Storage, a: Allocator, key: []const u8) !?FileInfo {
        return s.vtable.stat(s.ptr, a, try checkKey(key));
    }

    pub fn exists(s: Storage, key: []const u8) !bool {
        var buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        return (try s.stat(fba.allocator(), key)) != null;
    }

    /// Removing a file that isn't there is fine.
    pub fn delete(s: Storage, key: []const u8) !void {
        return s.vtable.delete(s.ptr, try checkKey(key));
    }

    pub fn list(s: Storage, a: Allocator, options: ListOptions) !ListPage {
        if (options.limit < 1 or options.limit > 1000) return error.InvalidLimit;
        return s.vtable.list(s.ptr, a, options);
    }

    /// A link to the file that works without credentials (S3 presigns it);
    /// `error.NoUrl` for drivers that can't make one.
    pub fn url(s: Storage, a: Allocator, key: []const u8, options: UrlOptions) ![]const u8 {
        return s.vtable.url(s.ptr, a, try checkKey(key), options);
    }
};

/// KickJS `checkKey`: segments separated by `/`, none empty, `.` or `..`,
/// and no `\` or NUL.
pub fn checkKey(key: []const u8) Error![]const u8 {
    if (key.len == 0 or std.mem.findAny(u8, key, "\\\x00") != null) return error.InvalidKey;
    var it = std.mem.splitScalar(u8, key, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidKey;
    }
    return key;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn nowS(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
}

/// In memory, for tests (KickJS `memoryStorage`).
pub const Memory = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    files: std.StringArrayHashMapUnmanaged(File) = .empty,

    const File = struct { data: []u8, content_type: ?[]u8, at: i64 };

    pub fn init(io: Io, gpa: Allocator) Memory {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(m: *Memory) void {
        for (m.files.keys(), m.files.values()) |k, f| m.free(k, f);
        m.files.deinit(m.gpa);
    }

    pub fn storage(m: *Memory) Storage {
        return .{ .ptr = m, .vtable = &vtable };
    }

    const vtable: Storage.VTable = .{ .put = put, .get = get, .stat = stat, .delete = delete, .list = list, .url = noUrl };

    fn free(m: *Memory, key: []const u8, f: File) void {
        m.gpa.free(key);
        m.gpa.free(f.data);
        if (f.content_type) |ct| m.gpa.free(ct);
    }

    fn put(ptr: *anyopaque, key: []const u8, data: []const u8, options: PutOptions) anyerror!void {
        const m: *Memory = @ptrCast(@alignCast(ptr));
        const copy = try m.gpa.dupe(u8, data);
        errdefer m.gpa.free(copy);
        const ct = if (options.content_type) |c| try m.gpa.dupe(u8, c) else null;
        errdefer if (ct) |c| m.gpa.free(c);
        const owned_key = try m.gpa.dupe(u8, key);
        errdefer m.gpa.free(owned_key);
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        if (m.files.fetchSwapRemove(key)) |old| m.free(old.key, old.value);
        try m.files.put(m.gpa, owned_key, .{ .data = copy, .content_type = ct, .at = nowS(m.io) });
    }

    fn get(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?[]u8 {
        const m: *Memory = @ptrCast(@alignCast(ptr));
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const f = m.files.get(key) orelse return null;
        return try a.dupe(u8, f.data);
    }

    fn stat(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?FileInfo {
        const m: *Memory = @ptrCast(@alignCast(ptr));
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const f = m.files.get(key) orelse return null;
        return try infoOf(a, key, f);
    }

    fn infoOf(a: Allocator, key: []const u8, f: File) !FileInfo {
        return .{
            .key = try a.dupe(u8, key),
            .size = f.data.len,
            .last_modified = f.at,
            .content_type = if (f.content_type) |c| try a.dupe(u8, c) else null,
        };
    }

    fn delete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const m: *Memory = @ptrCast(@alignCast(ptr));
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        if (m.files.fetchSwapRemove(key)) |old| m.free(old.key, old.value);
    }

    fn list(ptr: *anyopaque, a: Allocator, options: ListOptions) anyerror!ListPage {
        const m: *Memory = @ptrCast(@alignCast(ptr));
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        var keys: std.ArrayList([]const u8) = .empty;
        for (m.files.keys()) |k| if (inPage(k, options)) try keys.append(a, k);
        std.mem.sort([]const u8, keys.items, {}, lessThan);
        const n = @min(keys.items.len, options.limit);
        const files = try a.alloc(FileInfo, n);
        for (keys.items[0..n], files) |k, *f| f.* = try infoOf(a, k, m.files.get(k).?);
        return .{ .files = files, .cursor = if (keys.items.len > n) files[n - 1].key else null };
    }
};

fn inPage(key: []const u8, options: ListOptions) bool {
    if (!std.mem.startsWith(u8, key, options.prefix)) return false;
    if (options.cursor) |c| if (std.mem.order(u8, key, c) != .gt) return false;
    return true;
}

fn noUrl(_: *anyopaque, _: Allocator, _: []const u8, _: UrlOptions) anyerror![]const u8 {
    return error.NoUrl;
}

/// Files under a folder, `<root>/<key>` (KickJS `diskStorage`). A write goes
/// to a temporary file first and is renamed, so a reader never sees half a
/// file.
pub const Disk = struct {
    io: Io,
    /// Relative to the working directory, or absolute.
    root: []const u8,

    pub fn storage(d: *Disk) Storage {
        return .{ .ptr = d, .vtable = &vtable };
    }

    const vtable: Storage.VTable = .{ .put = put, .get = get, .stat = stat, .delete = delete, .list = list, .url = noUrl };

    fn open(d: *Disk, create: bool) !?Io.Dir {
        if (create) return try Io.Dir.cwd().createDirPathOpen(d.io, d.root, .{ .open_options = .{ .iterate = true } });
        return Io.Dir.cwd().openDir(d.io, d.root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn put(ptr: *anyopaque, key: []const u8, data: []const u8, _: PutOptions) anyerror!void {
        const d: *Disk = @ptrCast(@alignCast(ptr));
        var root = (try d.open(true)).?;
        defer root.close(d.io);
        if (std.fs.path.dirname(key)) |parent| try root.createDirPath(d.io, parent);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const temp = try std.mem.print(&buf, "{s}.{s}.tmp", .{ key, &@import("multipart.zig").uuid(d.io) });
        try root.writeFile(d.io, .{ .sub_path = temp, .data = data });
        errdefer root.deleteFile(d.io, temp) catch {};
        try root.rename(temp, root, key, d.io);
    }

    fn get(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?[]u8 {
        const d: *Disk = @ptrCast(@alignCast(ptr));
        var root = try d.open(false) orelse return null;
        defer root.close(d.io);
        return root.readFileAlloc(d.io, key, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => null,
            else => err,
        };
    }

    fn stat(ptr: *anyopaque, a: Allocator, key: []const u8) anyerror!?FileInfo {
        const d: *Disk = @ptrCast(@alignCast(ptr));
        var root = try d.open(false) orelse return null;
        defer root.close(d.io);
        const st = root.statFile(d.io, key, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        if (st.kind != .file) return null;
        return .{ .key = try a.dupe(u8, key), .size = st.size, .last_modified = @intCast(@divFloor(st.mtime.toNanoseconds(), std.time.ns_per_s)) };
    }

    fn delete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const d: *Disk = @ptrCast(@alignCast(ptr));
        var root = try d.open(false) orelse return;
        defer root.close(d.io);
        root.deleteFile(d.io, key) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        };
    }

    // ponytail: walks the whole folder for each page; an index (or a walk
    // that seeks to the cursor) if folders grow to many thousands of files.
    fn list(ptr: *anyopaque, a: Allocator, options: ListOptions) anyerror!ListPage {
        const d: *Disk = @ptrCast(@alignCast(ptr));
        var root = try d.open(false) orelse return .{ .files = &.{} };
        defer root.close(d.io);
        var keys: std.ArrayList([]const u8) = .empty;
        var walker = try root.walk(a);
        defer walker.deinit();
        while (try walker.next(d.io)) |entry| {
            if (entry.kind != .file or std.mem.endsWith(u8, entry.path, ".tmp")) continue;
            const key = try a.dupe(u8, entry.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, key, std.fs.path.sep, '/');
            if (inPage(key, options)) try keys.append(a, key);
        }
        std.mem.sort([]const u8, keys.items, {}, lessThan);
        const n = @min(keys.items.len, options.limit);
        var files: std.ArrayList(FileInfo) = .empty;
        for (keys.items[0..n]) |k| if (try stat(ptr, a, k)) |info| try files.append(a, info);
        return .{ .files = files.items, .cursor = if (keys.items.len > n) keys.items[n - 1] else null };
    }
};

const testing = std.testing;

/// What every driver must do; each driver's tests call it.
pub fn expectContract(s: Storage) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try s.put("docs/a.txt", "hello", .{ .content_type = "text/plain" });
    try testing.expectEqualStrings("hello", (try s.get(a, "docs/a.txt")).?);
    const info = (try s.stat(a, "docs/a.txt")).?;
    try testing.expectEqual(5, info.size);
    try testing.expectEqualStrings("docs/a.txt", info.key);
    try testing.expect(info.last_modified > 1_700_000_000);
    if (info.content_type) |ct| try testing.expectEqualStrings("text/plain", ct);
    try testing.expect(try s.exists("docs/a.txt"));

    // Missing: null, false, and a delete that succeeds.
    try testing.expectEqual(null, try s.get(a, "docs/nope"));
    try testing.expectEqual(null, try s.stat(a, "docs/nope"));
    try testing.expect(!try s.exists("docs/nope"));
    try s.delete("docs/nope");

    // Overwrite; any bytes.
    try s.put("docs/a.txt", "bye", .{});
    try testing.expectEqualStrings("bye", (try s.get(a, "docs/a.txt")).?);
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try s.put("bin/all", &all, .{});
    try testing.expectEqualSlices(u8, &all, (try s.get(a, "bin/all")).?);

    // Pages in key order, with a cursor.
    try s.put("docs/b.txt", "b", .{});
    try s.put("docs/c.txt", "c", .{});
    try s.put("docs-x/z", "z", .{});
    const first = try s.list(a, .{ .prefix = "docs/", .limit = 2 });
    try testing.expectEqual(2, first.files.len);
    try testing.expectEqualStrings("docs/a.txt", first.files[0].key);
    try testing.expectEqualStrings("docs/b.txt", first.files[1].key);
    try testing.expectEqual(1, first.files[1].size);
    const second = try s.list(a, .{ .prefix = "docs/", .limit = 2, .cursor = first.cursor.? });
    try testing.expectEqual(1, second.files.len);
    try testing.expectEqualStrings("docs/c.txt", second.files[0].key);
    try testing.expectEqual(null, second.cursor);
    try testing.expectEqual(5, (try s.list(a, .{})).files.len);

    try s.delete("docs/a.txt");
    try testing.expect(!try s.exists("docs/a.txt"));
    try testing.expectEqual(2, (try s.list(a, .{ .prefix = "docs/" })).files.len);

    for ([_][]const u8{ "", "../x", "a//b", "a/./b", "a\\b", "/abs", "a/" }) |bad| {
        try testing.expectError(error.InvalidKey, s.put(bad, "x", .{}));
        try testing.expectError(error.InvalidKey, s.get(a, bad));
    }
    try testing.expectError(error.InvalidLimit, s.list(a, .{ .limit = 1001 }));
}

test "memory storage keeps the contract" {
    var m: Memory = .init(testing.io, testing.allocator);
    defer m.deinit();
    try expectContract(m.storage());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoUrl, m.storage().url(arena.allocator(), "bin/all", .{}));
}

test "disk storage keeps the contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/files", .{tmp.sub_path});
    defer testing.allocator.free(root);
    var d: Disk = .{ .io = testing.io, .root = root };
    try expectContract(d.storage());
    // Nothing left half-written.
    var dir = try tmp.dir.openDir(testing.io, "files/docs", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| try testing.expect(!std.mem.endsWith(u8, e.name, ".tmp"));
}
