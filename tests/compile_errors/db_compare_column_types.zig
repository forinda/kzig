const kzig = @import("kzig");
const Role = enum {
    admin,
    member,
    pub const pg_name = "role";
};
const people = kzig.db.table("people", .{
    .id = .{ .type = .serial, .primary_key = true },
    .name = .{ .type = .text, .not_null = true },
    .email = .{ .type = .text, .unique = true },
    .role = .{ .type = .{ .@"enum" = Role }, .not_null = true, .default = .{ .value = "member" } },
}, .{});
const S = kzig.db.Schema(.{ .people = people }, .{});
export fn f() void {
    const c: kzig.db.Client(S) = .{ .conn = undefined };
    _ = c.selectFrom(.people).whereExpr(kzig.db.eq(.role, .name)).toSql(undefined) catch {};
}
