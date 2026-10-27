const std = @import("std");
const kzig = @import("kzig");
const CronService = @import("cron.service.zig").CronService;
const CronSecretGuard = @import("../../guards/cron-secret.guard.zig").CronSecretGuard;

pub const CronController = struct {
    cron: *CronService,
    jobs: *kzig.cron.Jobs,

    pub const docs = .{ .tags = &[_][]const u8{"Cron"} };

    pub const routes = .{
        .{ .method = .GET, .path = "/jobs", .handler = "list", .docs = .{ .summary = "Jobs with schedule, enabled state, last and next run" } },
        .{ .method = .POST, .path = "/jobs/:name/run", .handler = "run", .middleware = .{CronSecretGuard}, .docs = .{ .summary = "Run a job now", .bearer_auth = true } },
    };

    pub fn list(self: *CronController, ctx: *kzig.Ctx) ![]const CronService.Listed {
        return self.cron.list(ctx.arena);
    }

    /// Respects the job's enabled state and overlap.
    pub fn run(self: *CronController, ctx: *kzig.Ctx, got: struct { params: struct { name: []const u8 } }) !kzig.cron.Result {
        if (self.jobs.find(got.params.name) == null)
            return ctx.fail(.not_found, try ctx.arena.print("No cron job named \"{s}\"", .{got.params.name}));
        return self.jobs.run(got.params.name, .manual);
    }
};
