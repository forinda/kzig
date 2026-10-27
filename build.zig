const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("kzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Apps ported from kickjs-examples-archive; their tests run with ours.
    const examples_step = b.step("examples", "Build the example apps");
    for (examples) |name| {
        const root = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/src/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kzig", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = name, .root_module = root });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    }

    // Each fixture must fail to compile with its message: the "compile error,
    // not boot error" guarantees.
    for (compile_errors) |case| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "kzig" });
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("tests/compile_errors/{s}.zig", .{case[0]})));
        run.addPrefixedFileArg("-Mkzig=", b.path("src/root.zig"));
        run.expectExitCode(1);
        run.expectStdErrMatch(case[1]);
        test_step.dependOn(&run.step);
    }
}

const examples = [_][]const u8{ "minimal-api", "multi-tenant-api" };

const compile_errors = [_][2][]const u8{
    .{ "missing_service", "repo: no service" },
    .{ "pointer_to_non_service", "alloc: no service" },
    .{ "field_without_default", "count needs a default or a service type" },
    .{ "dependency_cycle", "dependency cycle: " },
    .{ "unknown_handler", "has no handler lst" },
    .{ "duplicate_route", "duplicate route GET /api/v1/x/:key" },
    .{ "override_outside_test", "App overrides are only allowed in tests" },
    .{ "unknown_module_option", "Module has no option .paths" },
    .{ "module_path_without_slash", "M: module path must be empty or start with '/'" },
    .{ "api_prefix_without_slash", "api_prefix must be empty or start with '/'" },
    .{ "contributor_missing", "GET /api/v1/x: the handler needs 'a' but no contributor on this route provides it" },
    .{ "contributor_cycle", "GET /api/v1/x: contributor cycle a -> b -> a" },
    .{ "contributor_duplicate", "GET /api/v1/x: contributor key 'a' registered twice" },
    .{ "contributor_optional_as_required", "'a' is optional; the handler must declare it as ?u32" },
    .{ "contributor_wrong_type", "'a' is u32, not []const u8 (in the handler)" },
    .{ "bad_middleware", "GET /api/v1/x: middleware must be fn (*Ctx, *Next) !void or a type with handle" },
};
