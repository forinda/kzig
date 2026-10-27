//! cron-jobs-api's `cron.test.ts` (without the serverless trigger route).
const std = @import("std");
const kzig = @import("kzig");
const test_app = @import("../../test_app.zig");
const Supplier = @import("cron.jobs.zig").Supplier;
const CronErrorsAdapter = @import("../../adapters/cron-errors.adapter.zig").CronErrorsAdapter;

const testing = std.testing;
const secret = "test-cron-secret-0123456789";
const bearer: kzig.Header = .{ .name = "authorization", .value = "Bearer " ++ secret };
const env = [_][2][]const u8{
    .{ "CRON_SECRET", secret },
    .{ "CRON_DISABLED_JOBS", "purge-sessions" },
    .{ "INVENTORY_SYNC_MS", "200" },
};

fn seconds(comptime iso: []const u8) i64 {
    const y = std.fmt.parseInt(i32, iso[0..4], 10) catch unreachable;
    const mo = std.fmt.parseInt(u8, iso[5..7], 10) catch unreachable;
    const d = std.fmt.parseInt(u8, iso[8..10], 10) catch unreachable;
    const h = std.fmt.parseInt(i64, iso[11..13], 10) catch unreachable;
    const mi = std.fmt.parseInt(i64, iso[14..16], 10) catch unreachable;
    return kzig.cron.civil(y, mo, d) * 86400 + h * 3600 + mi * 60;
}

test "cron: next run times follow each schedule" {
    const from = seconds("2026-01-15T10:00");
    inline for (.{ .{ "*/5 * * * *", "2026-01-15T10:05" }, .{ "*/2 * * * *", "2026-01-15T10:02" }, .{ "0 * * * *", "2026-01-15T11:00" } }) |c| {
        try testing.expectEqual(@as(?i64, seconds(c[1])), (try kzig.cron.Expr.parse(c[0])).next(from));
    }
}

test "cron: 02:00 Nairobi is 23:00 UTC" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    const jobs = t.app.get(kzig.cron.Jobs);
    const nightly = jobs.find("nightly-report").?;
    try testing.expectEqual(@as(?i64, seconds("2026-01-15T23:00")), jobs.next(nightly, seconds("2026-01-15T10:00")));
    try testing.expectEqual(@as(?i64, seconds("2026-01-16T23:00")), jobs.next(nightly, seconds("2026-01-15T23:30")));
}

const Listed = struct {
    name: []const u8,
    timezone: ?[]const u8,
    enabled: bool,
    nextRun: ?[]const u8,
    lastRun: ?struct { trigger: []const u8, status: []const u8, @"error": ?[]const u8 = null },
};

fn listed(t: test_app.TestApp, name: []const u8) !Listed {
    var res = try t.get("/api/v1/cron/jobs");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const all = try std.json.parseFromSlice([]const Listed, testing.allocator, res.body, .{ .ignore_unknown_fields = true });
    defer all.deinit();
    for (all.value) |j| if (std.mem.eql(u8, j.name, name)) {
        // Copied out of the parse: the test only reads the fixed fields.
        return .{
            .name = name,
            .timezone = if (j.timezone != null) "set" else null,
            .enabled = j.enabled,
            .nextRun = if (j.nextRun != null) "set" else null,
            .lastRun = if (j.lastRun) |l| .{
                .trigger = if (std.mem.eql(u8, l.trigger, "manual")) "manual" else "other",
                .status = if (std.mem.eql(u8, l.status, "ok")) "ok" else if (std.mem.eql(u8, l.status, "failed")) "failed" else "other",
                .@"error" = if (l.@"error") |e| (if (std.mem.eql(u8, e, "SupplierDown")) "SupplierDown" else "other") else null,
            } else null,
        };
    };
    return error.NotListed;
}

test "cron: lists every job with schedule, enabled state and next run" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    var res = try t.get("/api/v1/cron/jobs");
    defer res.deinit();
    const all = try std.json.parseFromSlice([]const struct { name: []const u8 }, testing.allocator, res.body, .{ .ignore_unknown_fields = true });
    defer all.deinit();
    try testing.expectEqual(4, all.value.len);
    const nightly = try listed(t, "nightly-report");
    try testing.expectEqualStrings("set", nightly.timezone.?);
    try testing.expect(nightly.enabled and nightly.lastRun == null and nightly.nextRun != null);
    const purge = try listed(t, "purge-sessions");
    try testing.expect(!purge.enabled and purge.nextRun == null);
}

test "cron: runs a job directly and records its last run" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    try testing.expectEqual(kzig.cron.Result{ .ran = 1, .failed = 0 }, t.app.get(kzig.cron.Jobs).run("warm-cache", .manual));
    const last = (try listed(t, "warm-cache")).lastRun.?;
    try testing.expectEqualStrings("manual", last.trigger);
    try testing.expectEqualStrings("ok", last.status);
}

test "cron: skips a disabled job" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    try testing.expectEqual(kzig.cron.Result{ .ran = 0, .failed = 0 }, t.app.get(kzig.cron.Jobs).run("purge-sessions", .manual));
}

test "cron: skips a run while the previous one is still going" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    const jobs = t.app.get(kzig.cron.Jobs);
    var first = try testing.io.concurrent(kzig.cron.Jobs.run, .{ jobs, "sync-inventory", kzig.cron.Trigger.manual });
    while (!jobs.isRunning(jobs.find("sync-inventory").?)) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(kzig.cron.Result{ .ran = 0, .failed = 0 }, jobs.run("sync-inventory", .manual));
    try testing.expectEqual(kzig.cron.Result{ .ran = 1, .failed = 0 }, first.await(testing.io));
}

test "cron: reports a failed run to the error observers" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    t.app.get(Supplier).down = true;
    try testing.expectEqual(kzig.cron.Result{ .ran = 0, .failed = 1 }, t.app.get(kzig.cron.Jobs).run("sync-inventory", .manual));
    const reports = t.app.get(CronErrorsAdapter);
    try testing.expectEqual(1, reports.count);
    try testing.expectEqualStrings("sync-inventory", reports.last.?.job);
    try testing.expectEqualStrings("*/2 * * * *", reports.last.?.expression);
    try testing.expectEqual(kzig.cron.Trigger.manual, reports.last.?.trigger);
    const last = (try listed(t, "sync-inventory")).lastRun.?;
    try testing.expectEqualStrings("failed", last.status);
    try testing.expectEqualStrings("SupplierDown", last.@"error".?);
}

test "cron: guards the manual run endpoint with CRON_SECRET" {
    const t = try test_app.boot(&env);
    defer t.deinit();
    var none = try t.request(.{ .method = .POST, .target = "/api/v1/cron/jobs/warm-cache/run" });
    defer none.deinit();
    try testing.expectEqual(.unauthorized, none.status);
    var wrong = try t.request(.{ .method = .POST, .target = "/api/v1/cron/jobs/warm-cache/run", .headers = &.{.{ .name = "authorization", .value = "Bearer nope" }} });
    defer wrong.deinit();
    try testing.expectEqual(.unauthorized, wrong.status);
    var missing = try t.request(.{ .method = .POST, .target = "/api/v1/cron/jobs/nope/run", .headers = &.{bearer} });
    defer missing.deinit();
    try testing.expectEqual(.not_found, missing.status);
    var ok = try t.request(.{ .method = .POST, .target = "/api/v1/cron/jobs/warm-cache/run", .headers = &.{bearer} });
    defer ok.deinit();
    try testing.expectEqual(.ok, ok.status);
    try testing.expectEqualStrings("{\"ran\":1,\"failed\":0}", ok.body);
}
