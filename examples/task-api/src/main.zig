const std = @import("std");
const kzig = @import("kzig");
const Config = @import("config/config.zig").Config;
const AppSettings = @import("config/app.settings.zig").AppSettings;
const modules = @import("modules.zig").modules;
const MailAdapter = @import("adapters/mail.adapter.zig").MailAdapter;
const mail = @import("adapters/mail.settings.zig");
const FileSettings = @import("modules/files/file.settings.zig").FileSettings;
const CronErrorsAdapter = @import("adapters/cron-errors.adapter.zig").CronErrorsAdapter;
const StorageAdapter = @import("adapters/storage.adapter.zig").StorageAdapter;
const DbAdapter = @import("adapters/db.adapter.zig").DbAdapter;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .settings = &.{AppSettings},
    // /openapi.json, /docs (Swagger UI), /redoc — development and test only.
    .plugins = &.{kzig.swagger.Plugin(.{
        .info = .{ .title = "task-api", .version = "0.1.0", .description = "kzig's example app" },
        .disable_in_prod = true,
    })},
    // ws://…/ws/<gateway path>; pings every 30 s.
    .ws = .{ .heartbeat_ms = 30_000 },
    .adapters = &.{
        MailAdapter("transactional", mail.TransactionalMail),
        MailAdapter("marketing", mail.MarketingMail),
        CronErrorsAdapter,
        StorageAdapter,
        DbAdapter,
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
    // An upload's body is the file plus its form: allow a megabyte over the file limit.
    const max_body = app.get(FileSettings).max_upload_bytes + 1024 * 1024;
    try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .port = app.get(Config).port, .max_body_bytes = max_body });
}

test {
    _ = @import("modules/hello/hello.test.zig");
    _ = @import("modules/projects/project.test.zig");
    _ = @import("modules/features/feature.test.zig");
    _ = @import("modules/config-reports/config-report.test.zig");
    _ = @import("adapters/mail.test.zig");
    _ = @import("openapi.test.zig");
    _ = @import("clock.zig");
    _ = @import("modules/tasks/task.test.zig");
    _ = @import("modules/files/file.test.zig");
    _ = @import("modules/chats/chat.test.zig");
    _ = @import("modules/crons/cron.test.zig");
    _ = @import("modules/users/user.test.zig");
    _ = @import("db/schema.test.zig");
    // kzig:tests
}
