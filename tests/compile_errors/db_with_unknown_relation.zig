const kzig = @import("kzig");
const users = kzig.db.table("users", .{ .id = .{ .type = .serial, .primary_key = true } }, .{});
const S = kzig.db.Schema(.{ .users = users }, .{});
export fn f() void {
    const c: kzig.db.Client(S) = .{ .conn = undefined };
    _ = c.query(.users).toSql(undefined, .{ .with = .{ .posts = true } }, false) catch {};
}
