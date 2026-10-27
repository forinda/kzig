const kzig = @import("kzig");
const Repo = struct {};
const Service = struct { repo: *Repo };
const C = struct {
    service: *Service,
    pub const routes = .{};
};
const A = kzig.App(.{ .modules = &.{kzig.Module(.{ .name = "M", .controllers = &.{C}, .services = &.{Service} })} });
export fn entry() void {
    var app: A = undefined;
    app.init(undefined, undefined, undefined) catch {};
}
