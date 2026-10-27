//! `kzig` — scaffolding for kzig apps (KickJS's `kick` CLI).
//!
//!   kzig new <name> [--kzig <path>] [--no-fetch] [--force]
//!   kzig g module <name> [--minimal] [--force]
//!   kzig g controller|service <name> [--module <dir>] [--force]
//!   kzig g middleware|contributor|adapter <name> [--force]
//!   kzig rm module <name>
const std = @import("std");
const Names = @import("names.zig").Names;
const render = @import("templates.zig").render;
const registry = @import("registry.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\kzig — scaffolding for kzig apps
    \\
    \\  kzig new <name> [--kzig <path>] [--no-fetch] [--force]
    \\      A project in ./<name>: an App with a hello module, tests, Swagger.
    \\      --kzig <path>  depend on a local kzig checkout instead of fetching it
    \\
    \\  kzig g module <name> [--minimal] [--force]
    \\      A REST module in src/modules/<plural>: module, controller, service,
    \\      in-memory repository, list query, tests; mounted in src/modules.zig.
    \\      --minimal: module, controller and test only.
    \\
    \\  kzig g controller|service <name> [--module <dir>]
    \\  kzig g middleware|contributor|adapter <name>
    \\      One file to wire in yourself.
    \\
    \\  kzig rm module <name> [--force]
    \\      Deletes the module's folder and unmounts it (asks first unless --force).
    \\
;

const kzig_url = "git+https://github.com/forinda/kzig";

const Template = struct {
    path: []const u8,
    body: []const u8,
};

fn tpl(comptime path: []const u8, comptime file: []const u8) Template {
    return .{ .path = path, .body = @embedFile("templates/" ++ file) };
}

const project_files = [_]Template{
    tpl("build.zig", "project/build.zig.tpl"),
    tpl("build.zig.zon", "project/build.zig.zon.tpl"),
    tpl(".gitignore", "project/gitignore.tpl"),
    tpl("README.md", "project/README.md.tpl"),
    tpl("src/main.zig", "project/main.zig.tpl"),
    tpl("src/config.zig", "project/config.zig.tpl"),
    tpl("src/modules.zig", "project/modules.zig.tpl"),
    tpl("src/test_app.zig", "project/test_app.zig.tpl"),
    tpl("src/modules/hello/hello.module.zig", "project/hello.module.zig.tpl"),
    tpl("src/modules/hello/hello.controller.zig", "project/hello.controller.zig.tpl"),
    tpl("src/modules/hello/hello.service.zig", "project/hello.service.zig.tpl"),
    tpl("src/modules/hello/hello.test.zig", "project/hello.test.zig.tpl"),
};

const rest_files = [_]Template{
    tpl("{{kebab}}.module.zig", "rest/module.zig.tpl"),
    tpl("{{kebab}}.controller.zig", "rest/controller.zig.tpl"),
    tpl("{{kebab}}.service.zig", "rest/service.zig.tpl"),
    tpl("{{kebab}}.repository.zig", "rest/repository.zig.tpl"),
    tpl("{{kebab}}.constants.zig", "rest/constants.zig.tpl"),
    tpl("{{kebab}}.test.zig", "rest/test.zig.tpl"),
};

const minimal_files = [_]Template{
    tpl("{{kebab}}.module.zig", "minimal/module.zig.tpl"),
    tpl("{{kebab}}.controller.zig", "minimal/controller.zig.tpl"),
    tpl("{{kebab}}.test.zig", "minimal/test.zig.tpl"),
};

const Stub = struct { kind: []const u8, dir: ?[]const u8, template: Template };

const stubs = [_]Stub{
    .{ .kind = "controller", .dir = null, .template = tpl("{{kebab}}.controller.zig", "stub/controller.zig.tpl") },
    .{ .kind = "service", .dir = null, .template = tpl("{{kebab}}.service.zig", "stub/service.zig.tpl") },
    .{ .kind = "middleware", .dir = "src/middleware", .template = tpl("{{kebab}}.middleware.zig", "stub/middleware.zig.tpl") },
    .{ .kind = "contributor", .dir = "src/contributors", .template = tpl("{{kebab}}.contributor.zig", "stub/contributor.zig.tpl") },
    .{ .kind = "adapter", .dir = "src/adapters", .template = tpl("{{kebab}}.adapter.zig", "stub/adapter.zig.tpl") },
};

const Cli = struct {
    io: Io,
    arena: Allocator,
    gpa: Allocator,
    out: *Io.Writer,
    cwd: Io.Dir,

    fn print(cli: Cli, comptime fmt: []const u8, args: anytype) void {
        cli.out.print(fmt, args) catch {};
        cli.out.flush() catch {};
    }
};

const Flags = struct {
    positional: []const []const u8,
    force: bool = false,
    minimal: bool = false,
    no_fetch: bool = false,
    kzig: ?[]const u8 = null,
    module: ?[]const u8 = null,
};

fn parse(arena: Allocator, args: []const [:0]const u8) !Flags {
    var positional: std.ArrayList([]const u8) = .empty;
    var flags: Flags = .{ .positional = &.{} };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--force")) {
            flags.force = true;
        } else if (std.mem.eql(u8, a, "--minimal")) {
            flags.minimal = true;
        } else if (std.mem.eql(u8, a, "--no-fetch")) {
            flags.no_fetch = true;
        } else if (std.mem.eql(u8, a, "--kzig") or std.mem.eql(u8, a, "--module")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            if (a[2] == 'k') flags.kzig = args[i] else flags.module = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else try positional.append(arena, a);
    }
    flags.positional = positional.items;
    return flags;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const cli: Cli = .{ .io = init.io, .arena = arena, .gpa = init.gpa, .out = &stdout.interface, .cwd = Io.Dir.cwd() };

    const args = try init.minimal.args.toSlice(arena);
    const flags = parse(arena, args[1..]) catch |err| {
        cli.print("error: {t}\n\n{s}", .{ err, usage });
        return 2;
    };
    run(cli, flags) catch |err| {
        switch (err) {
            error.Usage => cli.print("{s}", .{usage}),
            error.InvalidName => cli.print("error: a name starts with a letter and has letters, digits, '-' or '_'\n", .{}),
            error.NotAProject => cli.print("error: no src/modules.zig here — run this in a kzig project (made by `kzig new`)\n", .{}),
            error.Exists => {},
            else => cli.print("error: {t}\n", .{err}),
        }
        return if (err == error.Usage) 2 else 1;
    };
    return 0;
}

fn run(cli: Cli, flags: Flags) !void {
    const p = flags.positional;
    if (p.len == 0 or std.mem.eql(u8, p[0], "help")) return error.Usage;
    const cmd = p[0];
    if (std.mem.eql(u8, cmd, "new")) {
        if (p.len != 2) return error.Usage;
        return newProject(cli, flags, p[1]);
    }
    if (std.mem.eql(u8, cmd, "g") or std.mem.eql(u8, cmd, "generate")) {
        if (p.len != 3) return error.Usage;
        if (std.mem.eql(u8, p[1], "module")) return generateModule(cli, flags, p[2]);
        for (stubs) |s| if (std.mem.eql(u8, p[1], s.kind)) return generateStub(cli, flags, s, p[2]);
        return error.Usage;
    }
    if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "remove")) {
        if (p.len != 3 or !std.mem.eql(u8, p[1], "module")) return error.Usage;
        return removeModule(cli, flags, p[2]);
    }
    return error.Usage;
}

/// `name`, or `@"name"` when Zig reserves it (`error`, `test`, `type`).
fn identifier(a: Allocator, name: []const u8) ![]const u8 {
    if (std.zig.isValidId(name) and !std.zig.primitives.isPrimitive(name)) return name;
    return std.fmt.allocPrint(a, "@\"{s}\"", .{name});
}

fn vars(n: Names, extra: []const [2][]const u8, a: Allocator) ![]const [2][]const u8 {
    const base = [_][2][]const u8{
        .{ "Pascal", n.pascal },
        .{ "camel", n.camel },
        .{ "camelId", try identifier(a, n.camel) },
        .{ "kebab", n.kebab },
        .{ "snake", n.snake },
        .{ "plural", n.plural },
        .{ "PluralPascal", n.plural_pascal },
    };
    return std.mem.concat(a, [2][]const u8, &.{ &base, extra });
}

/// Writes every template under `dir`, refusing (before writing anything) if
/// a file exists and `force` is off.
fn writeAll(cli: Cli, dir: []const u8, templates: []const Template, v: []const [2][]const u8, force: bool) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    for (templates) |t| {
        const rel = try render(cli.arena, t.path, v);
        const path = try std.fs.path.join(cli.arena, &.{ dir, rel });
        try paths.append(cli.arena, path);
        if (!force) {
            if (cli.cwd.access(cli.io, path, .{})) |_| {
                cli.print("error: {s} exists (use --force to overwrite)\n", .{path});
                return error.Exists;
            } else |_| {}
        }
    }
    for (templates, paths.items) |t, path| {
        if (std.fs.path.dirname(path)) |d| try cli.cwd.createDirPath(cli.io, d);
        try cli.cwd.writeFile(cli.io, .{ .sub_path = path, .data = try render(cli.arena, t.body, v) });
        cli.print("  create {s}\n", .{path});
    }
}

fn newProject(cli: Cli, flags: Flags, raw: []const u8) !void {
    const n = try Names.init(cli.arena, raw);
    const dir = n.kebab;
    // The package name in build.zig.zon is a bare Zig identifier of at most
    // 32 bytes (as `zig init` requires).
    if (!std.zig.isValidId(n.snake) or std.zig.primitives.isPrimitive(n.snake) or n.snake.len > 32) {
        cli.print("error: '{s}' can't be a Zig package name: it must not be a keyword or primitive, and at most 32 characters\n", .{n.snake});
        return error.Exists;
    }

    var dependency: []const u8 = "";
    if (flags.kzig) |kzig_path| {
        const kzig_abs = cli.cwd.realPathFileAlloc(cli.io, kzig_path, cli.arena) catch {
            cli.print("error: --kzig {s}: no such directory\n", .{kzig_path});
            return error.Exists;
        };
        try cli.cwd.createDirPath(cli.io, dir);
        const project_abs = try cli.cwd.realPathFileAlloc(cli.io, dir, cli.arena);
        const rel = try std.fs.path.relativeAlloc(cli.arena, project_abs, null, project_abs, kzig_abs);
        dependency = try std.fmt.allocPrint(cli.arena, "        .kzig = .{{ .path = \"{s}\" }},\n", .{rel});
    }

    var id_bytes: [4]u8 = undefined;
    cli.io.random(&id_bytes);
    // Zig's package fingerprint: a random id (never 0 or all ones) and the
    // name's CRC32.
    const id = std.math.clamp(std.mem.readInt(u32, &id_bytes, .little), 1, 0xfffffffe);
    const fingerprint: u64 = @as(u64, std.hash.Crc32.hash(n.snake)) << 32 | id;

    const v = try vars(n, &.{
        .{ "fingerprint", try std.fmt.allocPrint(cli.arena, "0x{x}", .{fingerprint}) },
        .{ "dependency", dependency },
    }, cli.arena);
    cli.print("Creating {s}\n", .{dir});
    try writeAll(cli, dir, &project_files, v, flags.force);

    if (flags.kzig == null) {
        if (flags.no_fetch) {
            cli.print("\nAdd kzig: cd {s} && zig fetch --save=kzig {s}\n", .{ dir, kzig_url });
        } else {
            cli.print("  fetch kzig ({s})\n", .{kzig_url});
            const result = try std.process.run(cli.gpa, cli.io, .{
                .argv = &.{ "zig", "fetch", "--save=kzig", kzig_url },
                .cwd = .{ .path = dir },
            });
            defer cli.gpa.free(result.stdout);
            defer cli.gpa.free(result.stderr);
            if (!result.term.success()) {
                cli.print("error: zig fetch failed:\n{s}\nRun it yourself: cd {s} && zig fetch --save=kzig {s}\n", .{ result.stderr, dir, kzig_url });
                return error.FetchFailed;
            }
        }
    }
    cli.print(
        \\
        \\Done. Next:
        \\  cd {s}
        \\  zig build test
        \\  NODE_ENV=development zig build run   # http://localhost:3000/api/v1/hello, /docs
        \\  kzig g module task
        \\
    , .{dir});
}

/// KickJS asks before deleting a module; `--force` skips it.
fn confirm(cli: Cli, dir: []const u8) !bool {
    cli.print("Delete {s} and everything in it? This cannot be undone. [y/N] ", .{dir});
    var buf: [64]u8 = undefined;
    var stdin = Io.File.stdin().reader(cli.io, &buf);
    const line = stdin.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn requireProject(cli: Cli) !void {
    cli.cwd.access(cli.io, "src/modules.zig", .{}) catch return error.NotAProject;
}

fn edit(cli: Cli, path: []const u8, comptime f: anytype, args: anytype) !void {
    const source = try cli.cwd.readFileAlloc(cli.io, path, cli.arena, .limited(1 << 20));
    const updated = try @call(.auto, f, .{cli.arena} ++ .{source} ++ args);
    if (std.mem.eql(u8, updated, source)) return;
    try cli.cwd.writeFile(cli.io, .{ .sub_path = path, .data = updated });
    cli.print("  update {s}\n", .{path});
}

fn generateModule(cli: Cli, flags: Flags, raw: []const u8) !void {
    try requireProject(cli);
    const n = try Names.init(cli.arena, raw);
    // Checked before writing, so a failure leaves nothing half done.
    const registry_source = try cli.cwd.readFileAlloc(cli.io, "src/modules.zig", cli.arena, .limited(1 << 20));
    if (std.mem.find(u8, registry_source, "// kzig:modules") == null) {
        cli.print("error: src/modules.zig has no `// kzig:modules` line; add it inside `modules` where new modules go\n", .{});
        return error.Exists;
    }
    const dir = try std.fmt.allocPrint(cli.arena, "src/modules/{s}", .{n.plural});
    const v = try vars(n, &.{}, cli.arena);
    try writeAll(cli, dir, if (flags.minimal) &minimal_files else &rest_files, v, flags.force);

    const mount = try std.fmt.allocPrint(cli.arena, "@import(\"modules/{s}/{s}.module.zig\").{s}Module,", .{ n.plural, n.kebab, n.pascal });
    try edit(cli, "src/modules.zig", registry.insert, .{ "modules", mount });
    const test_line = try std.fmt.allocPrint(cli.arena, "_ = @import(\"modules/{s}/{s}.test.zig\");", .{ n.plural, n.kebab });
    edit(cli, "src/main.zig", registry.insert, .{ "tests", test_line }) catch |err| switch (err) {
        error.MarkerNotFound => cli.print("  note: no `// kzig:tests` in src/main.zig; import {s} from your tests\n", .{test_line}),
        else => return err,
    };
    cli.print("Mounted at /api/v1/{s}\n", .{n.plural});
}

fn generateStub(cli: Cli, flags: Flags, s: Stub, raw: []const u8) !void {
    try requireProject(cli);
    const n = try Names.init(cli.arena, raw);
    const dir = s.dir orelse if (flags.module) |m| blk: {
        // A folder name, not a path: nothing outside src/modules.
        _ = Names.init(cli.arena, m) catch {
            cli.print("error: --module {s}: a module folder name (letters, digits, '-', '_')\n", .{m});
            return error.Exists;
        };
        const d = try std.fmt.allocPrint(cli.arena, "src/modules/{s}", .{m});
        cli.cwd.access(cli.io, d, .{}) catch {
            cli.print("error: --module {s}: no folder {s}\n", .{ m, d });
            return error.Exists;
        };
        break :blk d;
    } else "src";
    try writeAll(cli, dir, &.{s.template}, try vars(n, &.{}, cli.arena), flags.force);
}

fn removeModule(cli: Cli, flags: Flags, raw: []const u8) !void {
    try requireProject(cli);
    const n = try Names.init(cli.arena, raw);
    // Generated modules are plural (`tasks`); `kzig new`'s hello is not.
    const plural_dir = try std.fmt.allocPrint(cli.arena, "src/modules/{s}", .{n.plural});
    const single_dir = try std.fmt.allocPrint(cli.arena, "src/modules/{s}", .{n.kebab});
    const dir = if (cli.cwd.access(cli.io, plural_dir, .{})) |_| plural_dir else |_| if (cli.cwd.access(cli.io, single_dir, .{})) |_| single_dir else |_| {
        cli.print("error: no module folder {s} or {s}\n", .{ plural_dir, single_dir });
        return error.Exists;
    };
    if (!flags.force and !try confirm(cli, dir)) {
        cli.print("Nothing deleted.\n", .{});
        return error.Exists;
    }
    try cli.cwd.deleteTree(cli.io, dir);
    cli.print("  delete {s}\n", .{dir});
    const needle = try std.fmt.allocPrint(cli.arena, "\"modules/{s}/", .{std.fs.path.basename(dir)});
    try edit(cli, "src/modules.zig", registry.remove, .{needle});
    edit(cli, "src/main.zig", registry.remove, .{needle}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test {
    _ = @import("names.zig");
    _ = @import("templates.zig");
    _ = @import("registry.zig");
}
