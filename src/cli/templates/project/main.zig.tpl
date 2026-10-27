const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config.zig").Config;
const modules = @import("modules.zig").modules;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .middleware = .{
        kzig.middleware.requestId(),
        kzig.middleware.requestLogger(.{ .skip = &.{"/health"} }),
        kzig.middleware.helmet(.{}),
    },
    // /openapi.json, /docs, /redoc — development and test only.
    .plugins = &.{kzig.swagger.Plugin(.{
        .info = .{ .title = "{{kebab}}", .version = "0.0.1" },
        .disable_in_prod = true,
    })},
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    // Until SIGINT/SIGTERM, then drains in-flight requests.
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .port = app.get(Config).port });
}

test {
    _ = @import("modules/hello/hello.test.zig");
    // kzig:tests
}
