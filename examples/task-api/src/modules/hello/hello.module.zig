const kzig = @import("kzig");
const HelloController = @import("hello.controller.zig").HelloController;
const HelloService = @import("hello.service.zig").HelloService;

pub const HelloModule = kzig.Module(.{
    .name = "HelloModule",
    .path = "/hello",
    .controllers = &.{HelloController},
    .services = &.{HelloService},
});
