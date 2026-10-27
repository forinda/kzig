const kzig = @import("kzig");
const C = struct {
    pub const routes = .{.{ .method = .POST, .path = "/", .handler = "up" }};
    pub fn up(_: *C, _: *kzig.Ctx, got: struct { body: struct { a: u8 }, upload: kzig.Upload(.{}) }) void {
        _ = got;
    }
};
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .path = "/m", .controllers = &.{C} })} });
comptime {
    _ = A.routes;
}
