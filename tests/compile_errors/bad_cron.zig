const kzig = @import("kzig");
const Jobs = struct {
    pub const crons = .{.{ .expression = "61 * * * *", .handler = "tick" }};
    pub fn tick(_: *Jobs, _: kzig.cron.Run) void {}
};
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .services = &.{Jobs} })} });
comptime {
    _ = A.routes;
    _ = A.init;
}
