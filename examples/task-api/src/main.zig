const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config/config.zig").Config;
const AppSettings = @import("config/app.settings.zig").AppSettings;
const modules = @import("modules.zig").modules;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .settings = &.{AppSettings},
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
    std.log.info("task-api listening on http://127.0.0.1:{d}", .{server.port()});
    try server.run();
}

test {
    _ = @import("modules/hello/hello.test.zig");
    _ = @import("modules/projects/project.test.zig");
    _ = @import("modules/features/feature.test.zig");
    _ = @import("modules/config-reports/config-report.test.zig");
}
