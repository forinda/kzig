//! File templates with `{{placeholder}}`s, filled by `render`.
const std = @import("std");

/// `template` with each `{{key}}` in `vars` replaced; unknown keys stay.
pub fn render(a: std.mem.Allocator, template: []const u8, vars: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.findPos(u8, template, i, "{{")) |found| {
        // `.{{{Name}}}`: the first brace is Zig's, the placeholder follows.
        var open = found;
        while (open + 2 < template.len and template[open + 2] == '{') open += 1;
        const close = std.mem.findPos(u8, template, open + 2, "}}") orelse break;
        const key = template[open + 2 .. close];
        const value = for (vars) |v| {
            if (std.mem.eql(u8, v[0], key)) break v[1];
        } else null;
        try out.appendSlice(a, template[i..open]);
        try out.appendSlice(a, value orelse template[open .. close + 2]);
        i = close + 2;
    }
    try out.appendSlice(a, template[i..]);
    return out.items;
}

const testing = std.testing;

test "render fills placeholders and leaves other braces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "pub const {{Pascal}} = struct {};\n// {{unknown}} {a}", &.{.{ "Pascal", "Task" }});
    try testing.expectEqualStrings("pub const Task = struct {};\n// {{unknown}} {a}", out);
}

test "a brace before a placeholder stays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), ".controllers = &.{{{Pascal}}Controller},", &.{.{ "Pascal", "Task" }});
    try testing.expectEqualStrings(".controllers = &.{TaskController},", out);
}
