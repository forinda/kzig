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
    const bin = options.bin orelse try binName(io, arena, cwd) orelse {
        try say(out, "error: no `addExecutable(.{{ .name = \"…\"` in build.zig; pass --bin <name>\n", .{});
        return error.NoBinary;
    };
    const exe = try arena.print("zig-out/bin/{s}", .{bin});
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, options.args });

    // The app reads NODE_ENV; dev means development unless said otherwise.
    var env = try environ.clone(arena);
    if (env.get("NODE_ENV") == null) try env.put("NODE_ENV", "development");

    signals.install();
    var seen = try snapshot(io, gpa, cwd);
    var app: ?std.process.Child = null;
    defer if (app) |*c| stop(io, c);

    if (try build(io, out)) app = try start(io, argv, &env, out);
    while (signals.count() == 0) {
        // ponytail: polls every 300 ms; inotify/kqueue would wake at once.
        io.sleep(.fromMilliseconds(300), .awake) catch break;
        const now = try snapshot(io, gpa, cwd);
        if (now == seen) continue;
        seen = now;
        try say(out, "\n[kzig dev] change detected, rebuilding…\n", .{});
        if (!try build(io, out)) {
            try say(out, "[kzig dev] build failed; the running app keeps serving\n", .{});
            continue;
        }
        if (app) |*c| stop(io, c);
        app = try start(io, argv, &env, out);
        try say(out, "[kzig dev] restarted\n", .{});
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

fn start(io: Io, argv: []const []const u8, env: *const std.process.Environ.Map, out: *Io.Writer) !std.process.Child {
    try say(out, "[kzig dev] {s}\n", .{argv[0]});
    return std.process.spawn(io, .{ .argv = argv, .environ_map = env });
}

/// SIGTERM, then wait: a kzig app drains its requests and exits.
fn stop(io: Io, child: *std.process.Child) void {
    child.kill(io);
}

/// The executable's name from build.zig: `addExecutable(.{ .name = "x"`.
fn binName(io: Io, arena: Allocator, cwd: Io.Dir) !?[]const u8 {
    const source = cwd.readFileAlloc(io, "build.zig", arena, .limited(1 << 20)) catch return null;
    const at = std.mem.find(u8, source, "addExecutable(") orelse return null;
    const name_at = std.mem.findPos(u8, source, at, ".name = \"") orelse return null;
    const start_i = name_at + ".name = \"".len;
    const end = std.mem.findScalarPos(u8, source, start_i, '"') orelse return null;
    return source[start_i..end];
}

/// A hash of every watched file's path, size and modification time.
fn snapshot(io: Io, gpa: Allocator, cwd: Io.Dir) !u64 {
    var h: std.hash.Wyhash = .init(0);
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |f| hashFile(io, cwd, f, &h);
    var src = cwd.openDir(io, "src", .{ .iterate = true }) catch return h.final();
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        h.update(entry.path);
        hashFile(io, src, entry.path, &h);
    }
    return h.final();
}

fn hashFile(io: Io, dir: Io.Dir, path: []const u8, h: *std.hash.Wyhash) void {
    const st = dir.statFile(io, path, .{}) catch return;
    h.update(std.mem.asBytes(&st.size));
    h.update(std.mem.asBytes(&st.mtime.nanoseconds));
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
