const kzig = @import("kzig");
const users = kzig.db.table("users", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const tags = kzig.db.table("tags", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const j = kzig.db.table("j", .{ .a = .{ .type = .integer, .references = .{ .to = "users.id" } }, .b = .{ .type = .integer, .references = .{ .to = "users.id" } }, .t = .{ .type = .integer, .references = .{ .to = "tags.id" } } }, .{});
comptime {
    _ = kzig.db.Schema(.{ .users = users, .tags = tags, .j = j }, .{ .relations = .{ .users = .{ .tags = .{ .many = .tags, .through = .{ .table = .j, .from = .{ .a, .b }, .to = .{.t} } } } } }).tables_info;
}
