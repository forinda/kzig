const kzig = @import("kzig");
const users = kzig.db.table("users", .{ .id = .{ .type = .serial, .primary_key = true }, .name = .{ .type = .text } }, .{});
const posts = kzig.db.table("posts", .{
    .id = .{ .type = .serial, .primary_key = true },
    .authorId = .{ .type = .integer, .references = .{ .to = "users.id" } },
}, .{});
const S = kzig.db.Schema(.{ .users = users, .posts = posts }, .{ .relations = .{
    .users = .{ .posts = .{ .many = .posts } },
    .posts = .{ .author = .{ .one = .users, .fields = .{.authorId}, .references = .{.id} } },
} });
export fn f() void {
    const c: kzig.db.Client(S) = .{ .conn = undefined };
    _ = c.query(.users).toSql(undefined, .{ .where = kzig.db.eq(.@"users.name", "x") }, false) catch {};
}
