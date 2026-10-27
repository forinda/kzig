//! kzig — KickJS for Zig. The public API is re-exported from here as milestones land.
const context = @import("context.zig");
const problem = @import("problem.zig");
const router = @import("router.zig");
const di = @import("di.zig");
const app = @import("app.zig");
pub const testing = @import("testing.zig");
pub const config = @import("config.zig");
pub const decode = @import("decode.zig");
pub const Issues = decode.Issues;
pub const FieldError = decode.FieldError;
const query = @import("query.zig");
pub const ListQuery = query.ListQuery;
pub const Paginated = query.Paginated;
pub const middleware = @import("middleware.zig");
pub const Next = middleware.Next;
pub const contributor = @import("contributor.zig");
pub const runtime = struct {
    pub const std = @import("runtime/std.zig");
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
pub const Process = app.Process;
pub const ConfigReport = app.ConfigReport;
pub const Version = app.Version;

test {
    _ = context;
    _ = problem;
    _ = router;
    _ = di;
    _ = app;
    _ = testing;
    _ = config;
    _ = decode;
    _ = query;
    _ = middleware;
    _ = runtime.std;
}
