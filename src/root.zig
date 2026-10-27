//! kzig — KickJS for Zig. The public API is re-exported from here as milestones land.
const context = @import("core/context.zig");
const problem = @import("core/problem.zig");
const router = @import("core/router.zig");
const di = @import("core/di.zig");
const app = @import("core/app.zig");
const adapter = @import("core/adapter.zig");
pub const StartInfo = adapter.StartInfo;
pub const RouteInfo = adapter.RouteInfo;
pub const testing = @import("core/testing.zig");
pub const config = @import("core/config.zig");
pub const decode = @import("core/decode.zig");
pub const Issues = decode.Issues;
pub const FieldError = decode.FieldError;
const query = @import("core/query.zig");
pub const ListQuery = query.ListQuery;
pub const Paginated = query.Paginated;
pub const Sort = query.Sort;
pub const Filter = query.Filter;
pub const openapi = @import("openapi/openapi.zig");
pub const multipart = @import("upload/multipart.zig");
/// WebSocket gateways (KickJS `@forinda/kickjs-ws`).
pub const ws = @import("ws/ws.zig");
/// Scheduled jobs (KickJS `@Cron`).
pub const cron = @import("cron/cron.zig");
/// PostgreSQL: pool, typed SQL, transactions, migrations (KickJS `@forinda/kickjs-db`).
pub const db = @import("db/db.zig");
/// File storage: memory, disk and S3 (KickJS `@forinda/kickjs-storage`).
pub const storage = @import("storage/storage.zig");
/// A WebSocket connection's loop, for runtimes (std, http.zig).
pub const ws_serve = @import("ws/serve.zig");
pub const Upload = multipart.Upload;
pub const UploadedFile = multipart.File;
pub const swagger = @import("openapi/swagger.zig");
pub const middleware = @import("core/middleware.zig");
pub const Next = middleware.Next;
pub const contributor = @import("core/contributor.zig");
pub const runtime = struct {
    pub const std = @import("runtime/std.zig");
    pub const Options = @import("runtime/options.zig").Options;
    /// Response rules every runtime applies before writing.
    pub const wire = @import("runtime/wire.zig");
    /// The socket-level behaviour every runtime shares; for runtime tests.
    pub const conformance = @import("runtime/conformance.zig");
    /// SIGINT/SIGTERM handling shared by runtimes' `serve`.
    pub const signals = @import("runtime/std.zig").signals;
};

pub const Ctx = context.Ctx;
pub const Request = context.Request;
pub const Response = context.Response;
pub const Header = context.Header;
pub const Problem = problem.Problem;
pub const Error = problem.Error;
pub const Route = router.Route;
pub const route = router.route;
pub const Router = router.Router;
pub const normalizePath = router.normalizePath;
pub const Container = di.Container;
pub const Module = app.Module;
pub const App = app.App;
pub const Plugin = app.Plugin;
pub const Process = app.Process;
pub const ConfigReport = app.ConfigReport;
pub const HealthCheck = @import("core/health.zig").HealthCheck;
pub const Version = app.Version;

// Every file's tests, listed so none is left out (cli/ is its own module;
// runtime/httpz.zig is built with -Dhttpz).
test {
    _ = @import("core/adapter.zig");
    _ = @import("core/app.zig");
    _ = @import("core/config.zig");
    _ = @import("core/context.zig");
    _ = @import("core/contributor.zig");
    _ = @import("core/decode.zig");
    _ = @import("core/di.zig");
    _ = @import("core/health.zig");
    _ = @import("core/middleware.zig");
    _ = @import("core/middleware/cors.zig");
    _ = @import("core/middleware/harness.zig");
    _ = @import("core/middleware/helmet.zig");
    _ = @import("core/middleware/request_id.zig");
    _ = @import("core/middleware/request_logger.zig");
    _ = @import("core/problem.zig");
    _ = @import("core/query.zig");
    _ = @import("core/router.zig");
    _ = @import("core/testing.zig");
    _ = @import("cron/cron.zig");
    _ = @import("db/db.zig");
    _ = @import("db/migrate.zig");
    _ = @import("db/pg.zig");
    _ = @import("openapi/openapi.zig");
    _ = @import("openapi/swagger.zig");
    _ = @import("runtime/conformance.zig");
    _ = @import("runtime/options.zig");
    _ = @import("runtime/std.zig");
    _ = @import("runtime/wire.zig");
    _ = @import("storage/s3.zig");
    _ = @import("storage/storage.zig");
    _ = @import("upload/multipart.zig");
    _ = @import("ws/frame.zig");
    _ = @import("ws/serve.zig");
    _ = @import("ws/ws.zig");
}
