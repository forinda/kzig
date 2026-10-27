const kzig = @import("kzig");
const people = kzig.db.table("people", .{
    .id = .{ .type = .serial, .primary_key = true },
}, .{});
const S = kzig.db.Schema(.{ .people = people }, .{});
export fn f() void {
    const c: kzig.db.Client(S) = .{ .conn = undefined };
    _ = c.selectFrom(.people).select(.{.nickname}).toSql(undefined) catch {};
}
