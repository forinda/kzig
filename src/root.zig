//! kzig — KickJS for Zig. The public API is re-exported from here as milestones land.
const context = @import("context.zig");
const problem = @import("problem.zig");
const router = @import("router.zig");
pub const testing = @import("testing.zig");

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

test {
    _ = context;
    _ = problem;
    _ = router;
    _ = testing;
}
