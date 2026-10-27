//! The spellings of a name the generators need: `task-list` →
//! `TaskList`, `taskList`, `task_list`, plural `task-lists`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Names = struct {
    pascal: []const u8,
    camel: []const u8,
    kebab: []const u8,
    snake: []const u8,
    plural: []const u8,
    plural_pascal: []const u8,

    /// `raw` in any of the spellings: kebab, snake, camel or Pascal case.
    pub fn init(a: Allocator, raw: []const u8) !Names {
        if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0])) return error.InvalidName;
        for (raw) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidName;

        var words: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        for (raw, 0..) |c, i| {
            const boundary = c == '-' or c == '_';
            const camel_step = i > 0 and std.ascii.isUpper(c) and std.ascii.isLower(raw[i - 1]);
            if (boundary or camel_step) {
                if (i > start) try words.append(a, try std.ascii.allocLowerString(a, raw[start..i]));
                start = if (boundary) i + 1 else i;
            }
        }
        if (raw.len > start) try words.append(a, try std.ascii.allocLowerString(a, raw[start..]));
        if (words.items.len == 0) return error.InvalidName;

        const kebab = try std.mem.join(a, "-", words.items);
        const pascal = try capitalized(a, words.items, true);
        const plural_kebab = try plural(a, kebab);
        var plural_words = try a.dupe([]const u8, words.items);
        plural_words[plural_words.len - 1] = try plural(a, words.items[words.items.len - 1]);
        return .{
            .pascal = pascal,
            .camel = try capitalized(a, words.items, false),
            .kebab = kebab,
            .snake = try std.mem.join(a, "_", words.items),
            .plural = plural_kebab,
            .plural_pascal = try capitalized(a, plural_words, true),
        };
    }
};

fn capitalized(a: Allocator, words: []const []const u8, first_upper: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        try out.appendSlice(a, w);
        const at = out.items.len - w.len;
        if (i > 0 or first_upper) out.items[at] = std.ascii.toUpper(out.items[at]);
    }
    return out.items;
}

/// English plural of a lower-case word, the common rules only.
pub fn plural(a: Allocator, word: []const u8) ![]const u8 {
    const vowels = "aeiou";
    if (word.len > 1 and word[word.len - 1] == 'y' and std.mem.findScalar(u8, vowels, word[word.len - 2]) == null)
        return std.mem.concat(a, u8, &.{ word[0 .. word.len - 1], "ies" });
    for ([_][]const u8{ "s", "x", "z", "ch", "sh" }) |end| {
        if (std.mem.endsWith(u8, word, end)) return std.mem.concat(a, u8, &.{ word, "es" });
    }
    return std.mem.concat(a, u8, &.{ word, "s" });
}

const testing = std.testing;

test "spellings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const n = try Names.init(arena.allocator(), "TaskList");
    try testing.expectEqualStrings("TaskList", n.pascal);
    try testing.expectEqualStrings("taskList", n.camel);
    try testing.expectEqualStrings("task-list", n.kebab);
    try testing.expectEqualStrings("task_list", n.snake);
    try testing.expectEqualStrings("task-lists", n.plural);
    try testing.expectEqualStrings("TaskLists", n.plural_pascal);
    const m = try Names.init(arena.allocator(), "user_profile");
    try testing.expectEqualStrings("UserProfile", m.pascal);
    try testing.expectEqualStrings("user-profiles", m.plural);
}

test "plurals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{ .{ "task", "tasks" }, .{ "category", "categories" }, .{ "box", "boxes" }, .{ "class", "classes" }, .{ "day", "days" }, .{ "branch", "branches" } }) |c|
        try testing.expectEqualStrings(c[1], try plural(a, c[0]));
}

test "invalid names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "1task", "task!", "-task", "a b" }) |bad|
        try testing.expectError(error.InvalidName, Names.init(arena.allocator(), bad));
}
