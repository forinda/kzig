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

const compile_errors = [_][2][]const u8{
    .{ "missing_service", "repo: no service" },
    .{ "pointer_to_non_service", "alloc: no service" },
    .{ "field_without_default", "count needs a default or a service type" },
    .{ "dependency_cycle", "dependency cycle: " },
    .{ "unknown_handler", "has no handler lst" },
    .{ "duplicate_route", "duplicate route GET /api/v1/x/:key" },
    .{ "override_outside_test", "App overrides are only allowed in tests" },
    .{ "unknown_module_option", "Module has no option .paths" },
};
