const kzig = @import("kzig");
const people = kzig.db.table("people", .{
    .id = .{ .type = .serial, .primary_key = true },
    .name = .{ .type = .text, .not_null = true },
}, .{});
const S = kzig.db.Schema(.{ .people = people }, .{});
export fn f() void {
    const c: kzig.db.Client(S) = .{ .conn = undefined };
    _ = c.selectFrom(.people).where(.name, .eq, 5).toSql(undefined) catch {};
}
