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
});

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();

    var server: kzig.runtime.std.Server(App) = try .init(init.io, init.gpa, &app, .{ .port = app.get(Config).port });
    defer server.deinit();
    std.log.info("multi-tenant-api listening on http://127.0.0.1:{d}", .{server.port()});
    try server.run();
}

test {
    _ = @import("modules/projects/project.test.zig");
}
