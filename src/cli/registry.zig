//! Lines the generators add to and remove from a project: before a
//! `// kzig:<marker>` line, at its indentation.
const std = @import("std");

/// `source` with `line` added before the `// kzig:<marker>` line, at its
/// indentation; unchanged when `line` is already there.
pub fn insert(a: std.mem.Allocator, source: []const u8, marker: []const u8, line: []const u8) ![]const u8 {
    const tag = try std.mem.concat(a, u8, &.{ "// kzig:", marker });
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, std.mem.trim(u8, l, " \t"), line)) return source;
        if (!found and std.mem.eql(u8, std.mem.trim(u8, l, " \t"), tag)) {
            found = true;
            const indent = l[0 .. l.len - std.mem.trimStart(u8, l, " \t").len];
            try out.print(a, "{s}{s}\n", .{ indent, line });
        }
        try out.appendSlice(a, l);
        if (it.index != null) try out.append(a, '\n');
    }
    if (!found) return error.MarkerNotFound;
    return out.items;
}

/// `source` without the lines containing `needle`.
pub fn remove(a: std.mem.Allocator, source: []const u8, needle: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |l| {
        if (std.mem.find(u8, l, needle) != null) continue;
        try out.appendSlice(a, l);
        if (it.index != null) try out.append(a, '\n');
    }
    return out.items;
}

const testing = std.testing;

const modules_zig =
    \\pub const modules: []const type = &.{
    \\    @import("modules/hellos/hello.module.zig").HelloModule,
    \\    // kzig:modules
    \\};
    \\
;

test "insert before the marker, once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "@import(\"modules/tasks/task.module.zig\").TaskModule,";
    const once = try insert(a, modules_zig, "modules", line);
    try testing.expectEqualStrings(
        \\pub const modules: []const type = &.{
        \\    @import("modules/hellos/hello.module.zig").HelloModule,
        \\    @import("modules/tasks/task.module.zig").TaskModule,
        \\    // kzig:modules
        \\};
        \\
    , once);
    try testing.expectEqualStrings(once, try insert(a, once, "modules", line));
    try testing.expectError(error.MarkerNotFound, insert(a, modules_zig, "tests", line));
}

test "remove lines naming a path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with = try insert(a, modules_zig, "modules", "@import(\"modules/tasks/task.module.zig\").TaskModule,");
    try testing.expectEqualStrings(modules_zig, try remove(a, with, "modules/tasks/"));
}
