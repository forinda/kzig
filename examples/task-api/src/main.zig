const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config/config.zig").Config;
const AppSettings = @import("config/app.settings.zig").AppSettings;
const modules = @import("modules.zig").modules;
const MailAdapter = @import("adapters/mail.adapter.zig").MailAdapter;
const mail = @import("adapters/mail.settings.zig");

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .settings = &.{AppSettings},
    .adapters = &.{
        MailAdapter("transactional", mail.TransactionalMail),
        MailAdapter("marketing", mail.MarketingMail),
    },
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

    // Until SIGINT/SIGTERM; then in-flight requests finish and `deinit`
    // runs the adapters' shutdown hooks.
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .port = app.get(Config).port });
}

test {
    _ = @import("modules/hello/hello.test.zig");
    _ = @import("modules/projects/project.test.zig");
    _ = @import("modules/features/feature.test.zig");
    _ = @import("modules/config-reports/config-report.test.zig");
    _ = @import("adapters/mail.test.zig");
}
