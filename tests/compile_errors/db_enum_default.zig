const kzig = @import("kzig");
const Role = enum {
    admin,
    pub const pg_name = "role";
};
const t = kzig.db.table("t", .{ .r = .{ .type = .{ .@"enum" = Role }, .default = .{ .value = "zzz" } } }, .{});
comptime {
    _ = t.Row;
}
