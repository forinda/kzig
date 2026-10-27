const kzig = @import("kzig");
const users = kzig.db.table("users", .{ .id = .{ .type = .serial, .primary_key = true }, .name = .{ .type = .text } }, .{});
const posts = kzig.db.table("posts", .{
    .id = .{ .type = .serial, .primary_key = true },
    .authorId = .{ .type = .integer, .references = .{ .to = "users.id" } },
    .editorId = .{ .type = .integer, .references = .{ .to = "users.id" } },
}, .{});
comptime {
    _ = kzig.db.Schema(.{ .users = users, .posts = posts }, .{ .relations = .{ .users = .{ .name = .{ .many = .posts } } } }).tables_info;
}
