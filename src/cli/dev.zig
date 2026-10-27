//! `kzig dev`: build, run, and on every change to `src/`, `build.zig` or
//! `build.zig.zon` rebuild and restart (KickJS's `kick dev`). A failed build
//! keeps the running app. `zig build run --watch` can't do this for a
//! server: its run step waits for the process to exit.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// The executable in zig-out/bin; found in build.zig when null.
    bin: ?[]const u8 = null,
    /// Passed to the app.
    args: []const []const u8 = &.{},
};

pub fn run(io: Io, gpa: Allocator, arena: Allocator, environ: *const std.process.Environ.Map, out: *Io.Writer, options: Options) !void {
    const cwd = Io.Dir.cwd();
    const bin = options.bin orelse try binName(io, arena, cwd) orelse return error.NoBinary;
    const exe = try arena.print("zig-out/bin/{s}", .{bin});
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, options.args });

    // The app reads NODE_ENV; dev means development unless said otherwise.
    var env = try environ.clone(arena);
    if (env.get("NODE_ENV") == null) try env.put("NODE_ENV", "development");

    signals.install();
    var seen = snapshot(io, gpa, cwd) orelse 0;
    var app: ?std.process.Child = null;
    defer if (app) |*c| stop(io, c);

    if (try build(io, out)) app = try start(io, argv, &env, out);
    while (signals.count() == 0) {
        // ponytail: polls every 300 ms; inotify/kqueue would wake at once.
        io.sleep(.fromMilliseconds(300), .awake) catch break;
        if (app) |c| if (exited(c.id.?)) {
            app = null;
            try say(out, "[kzig dev] the app exited; waiting for a change\n", .{});
        };
        // A directory removed mid-walk: look again on the next tick.
        const now = snapshot(io, gpa, cwd) orelse continue;
        if (now == seen) continue;
        seen = now;
        try say(out, "\n[kzig dev] change detected, rebuilding…\n", .{});
        if (!try build(io, out)) {
            try say(out, "[kzig dev] build failed; the running app keeps serving\n", .{});
            continue;
        }
        if (signals.count() != 0) break;
        if (app) |*c| stop(io, c);
        app = try start(io, argv, &env, out);
        if (app != null) try say(out, "[kzig dev] restarted\n", .{});
    }
    try say(out, "\n[kzig dev] stopping\n", .{});
}

fn say(out: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try out.print(fmt, args);
    try out.flush();
}

fn build(io: Io, out: *Io.Writer) !bool {
    try say(out, "[kzig dev] zig build\n", .{});
    var child = try std.process.spawn(io, .{ .argv = &.{ "zig", "build" } });
    const term = try child.wait(io);
    return term.success();
}

/// The app gets its own process group: Ctrl-C reaches kzig only, and the
/// app sees exactly one SIGTERM (a second one makes a kzig app skip its drain).
fn start(io: Io, argv: []const []const u8, env: *const std.process.Environ.Map, out: *Io.Writer) !?std.process.Child {
    try say(out, "[kzig dev] {s}\n", .{argv[0]});
    return std.process.spawn(io, .{ .argv = argv, .environ_map = env, .pgid = 0 }) catch |err| {
        try say(out, "[kzig dev] can't start {s}: {t}; waiting for a change\n", .{ argv[0], err });
        return null;
    };
}

/// SIGTERM and let the app drain; SIGKILL if it is still up after the grace.
fn stop(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, .TERM) catch {};
    for (0..stop_grace_ms / 50) |_| {
        if (exited(pid)) {
            child.id = null;
            return;
        }
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    std.posix.kill(pid, .KILL) catch {};
    _ = child.wait(io) catch {};
}

const stop_grace_ms = 10_000;

/// Reaps `pid` if it has exited, without blocking.
fn exited(pid: std.posix.pid_t) bool {
    var status: if (builtin.link_libc) c_int else i32 = undefined;
    const rc = std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => rc != 0,
        .INTR => false,
        else => true,
    };
}

/// The executable's name from build.zig: the first `addExecutable(.{ .name =
/// "x"` outside a comment. Null for a computed name (pass --bin).
fn binName(io: Io, arena: Allocator, cwd: Io.Dir) !?[]const u8 {
    const source = cwd.readFileAlloc(io, "build.zig", arena, .limited(1 << 20)) catch return null;
    var pos: usize = 0;
    while (std.mem.findPos(u8, source, pos, "addExecutable(")) |at| {
        pos = at + "addExecutable(".len;
        const line = if (std.mem.findScalarLast(u8, source[0..at], '\n')) |n| n + 1 else 0;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, source[line..at], " \t"), "//")) continue;
        const call = source[pos .. closing(source, pos) orelse return null];
        const name_at = std.mem.find(u8, call, ".name = ") orelse return null;
        const value = call[name_at + ".name = ".len ..];
        if (value.len == 0 or value[0] != '"') return null;
        const end = std.mem.findScalarPos(u8, value, 1, '"') orelse return null;
        // `"app" ++ suffix` is computed too.
        const after = std.mem.trimStart(u8, value[end + 1 ..], " \t\n");
        if (after.len == 0 or (after[0] != ',' and after[0] != '}')) return null;
        return value[1..end];
    }
    return null;
}

/// The `)` closing a call whose arguments start at `from` (strings holding
/// parentheses aside); null while the call is half-written.
fn closing(source: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    for (source[from..], from..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

/// A hash of every watched file's path, size and modification time.
/// Contents, not modification times: a coarse clock (HFS+ keeps seconds)
/// would miss a second same-size edit within the second.
/// ponytail: reads every source each tick; fine for an app's src/.
/// Only Zig sources count: editor swap and backup files would restart the app
/// while you type. Null when the walk fails (a directory removed under it).
fn snapshot(io: Io, gpa: Allocator, cwd: Io.Dir) ?u64 {
    var h: std.hash.Wyhash = .init(0);
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |f| hashFile(io, gpa, cwd, f, &h);
    var src = cwd.openDir(io, "src", .{ .iterate = true }) catch return h.final();
    defer src.close(io);
    var walker = src.walk(gpa) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch return null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig") and !std.mem.endsWith(u8, entry.path, ".zon")) continue;
        h.update(entry.path);
        hashFile(io, gpa, src, entry.path, &h);
    }
    return h.final();
}

fn hashFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, h: *std.hash.Wyhash) void {
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch {
        // Too big to read each tick (generated code): its size and time will do.
        const st = dir.statFile(io, path, .{}) catch return;
        h.update(std.mem.asBytes(&st.size));
        h.update(std.mem.asBytes(&st.mtime.nanoseconds));
        return;
    };
    defer gpa.free(bytes);
    h.update(bytes);
}

const signals = struct {
    var received: std.atomic.Value(u32) = .init(0);

    fn count() u32 {
        return received.load(.acquire);
    }

    fn handler(_: std.posix.SIG) callconv(.c) void {
        _ = received.fetchAdd(1, .acq_rel);
    }

    fn install() void {
        if (builtin.os.tag == .windows) return;
        const act: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
};

test "binName reads the executable's name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "const exe = b.addExecutable(.{ .name = \"demo-app\", .root_module = mod });" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("demo-app", (try binName(std.testing.io, arena.allocator(), tmp.dir)).?);
}

test "binName skips commented-out calls and doesn't read past the call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\// const old = b.addExecutable(.{ .name = "old" });
        \\const exe = b.addExecutable(.{ .name = "demo-app", .root_module = mod });
    });
    try std.testing.expectEqualStrings("demo-app", (try binName(io, a, tmp.dir)).?);

    // A computed name: not the `.name` of the test that follows.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const exe = b.addExecutable(.{ .name = name, .root_module = mod });
        \\const t = b.addTest(.{ .name = "unit", .root_module = mod });
    });
    try std.testing.expectEqual(null, try binName(io, a, tmp.dir));

    for ([_][]const u8{
        // Computed, though it starts with a literal.
        \\const exe = b.addExecutable(.{ .name = "app" ++ suffix });
        ,
        // Half-written: the call never closes.
        \\const exe = b.addExecutable(.{ .root_module = mod,
        \\const t = b.addTest(.{ .name = "unit" });
        ,
    }) |source| {
        try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = source });
        try std.testing.expectEqual(null, try binName(io, a, tmp.dir));
    }

    // `//` in a string isn't a comment.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const u = "http://x"; const exe = b.addExecutable(.{ .name = "demo-app" });
    });
    try std.testing.expectEqualStrings("demo-app", (try binName(io, a, tmp.dir)).?);
}

test "snapshot sees an edit that keeps the size and modification time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "aaa" });
    const mtime = (try tmp.dir.statFile(io, "src/a.zig", .{})).mtime;
    const before = snapshot(io, std.testing.allocator, tmp.dir).?;
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "bbb" });
    try tmp.dir.setTimestamps(io, "src/a.zig", .{ .modify_timestamp = .{ .new = mtime } });
    try std.testing.expect(snapshot(io, std.testing.allocator, tmp.dir).? != before);
}
