const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("kzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Local SQLite files need SQLite's C library: fetched and compiled only
    // with -Dsqlite, so the default build stays C-free. Turso and D1 don't.
    const kzig_options = b.addOptions();
    var sqlite = false;
    if (b.option(bool, "sqlite", "Build SQLite's C library for local sqlite: databases") orelse false) {
        if (b.lazyDependency("sqlite", .{})) |dep| {
            const header = b.addTranslateC(.{ .root_source_file = dep.path("sqlite3.h"), .target = target, .optimize = optimize });
            mod.addImport("sqlite3", header.createModule());
            mod.addCSourceFile(.{ .file = dep.path("sqlite3.c"), .flags = &.{
                "-DSQLITE_THREADSAFE=1",
                "-DSQLITE_DQS=0",
                "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
                "-DSQLITE_OMIT_LOAD_EXTENSION",
            } });
            mod.link_libc = true;
            sqlite = true;
        }
    }
    kzig_options.addOption(bool, "sqlite", sqlite);
    mod.addOptions("kzig_options", kzig_options);

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(runTests(b, tests));

    // The `kzig` CLI (kzig new, kzig g module, …).
    const cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli/main.zig"), .target = target, .optimize = optimize });
    // The release workflow passes the tag: `kzig new` then fetches that kzig.
    const cli_options = b.addOptions();
    cli_options.addOption(?[]const u8, "version", b.option([]const u8, "version", "Release tag the CLI scaffolds against"));
    cli_mod.addOptions("build_options", cli_options);
    // kzig db migrate runs the library's migrator.
    cli_mod.addImport("kzig", mod);
    const cli = b.addExecutable(.{ .name = "kzig", .root_module = cli_mod });
    b.installArtifact(cli);
    test_step.dependOn(runTests(b, b.addTest(.{ .root_module = cli_mod })));

    // The http.zig runtime is its own module behind -Dhttpz, so std-runtime
    // users never fetch http.zig.
    const bench_step = b.step("bench", "Build the benchmark servers (bench-httpz needs -Dhttpz)");
    addBench(b, bench_step, mod, null, target, optimize);
    addRouterBench(b, mod, target, optimize);
    if (b.option(bool, "httpz", "Build the http.zig runtime (kzig_httpz module)") orelse false) {
        if (b.lazyDependency("httpz", .{ .target = target, .optimize = optimize })) |dep| {
            const httpz_mod = b.addModule("kzig_httpz", .{
                .root_source_file = b.path("src/runtime/httpz.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kzig", .module = mod },
                    .{ .name = "httpz", .module = dep.module("httpz") },
                },
            });
            test_step.dependOn(runTests(b, b.addTest(.{ .root_module = httpz_mod })));
            addBench(b, bench_step, mod, httpz_mod, target, optimize);
        }
    }

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
        test_step.dependOn(runTests(b, b.addTest(.{ .root_module = root })));
    }

    // Each fixture must fail to compile with its message: the "compile error,
    // not boot error" guarantees.
    const no_sqlite = b.addOptions();
    no_sqlite.addOption(bool, "sqlite", false);
    for (compile_errors) |case| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "kzig" });
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("tests/compile_errors/{s}.zig", .{case[0]})));
        run.addArgs(&.{ "--dep", "kzig_options" });
        run.addPrefixedFileArg("-Mkzig=", b.path("src/root.zig"));
        run.addPrefixedFileArg("-Mkzig_options=", no_sqlite.getOutput());
        run.expectExitCode(1);
        run.expectStdErrMatch(case[1]);
        test_step.dependOn(&run.step);
    }
}

fn addRouterBench(b: *std.Build, kzig: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const root = b.createModule(.{ .root_source_file = b.path("benchmarks/router.zig"), .target = target, .optimize = optimize });
    root.addImport("kzig", kzig);
    const exe = b.addExecutable(.{ .name = "bench-router", .root_module = root });
    b.step("bench-router", "Build the route-matching benchmark").dependOn(&b.addInstallArtifact(exe, .{}).step);
}

fn addBench(b: *std.Build, step: *std.Build.Step, kzig: *std.Build.Module, httpz: ?*std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const options = b.addOptions();
    options.addOption(bool, "httpz", httpz != null);
    const root = b.createModule(.{ .root_source_file = b.path("benchmarks/bench.zig"), .target = target, .optimize = optimize });
    root.addImport("kzig", kzig);
    root.addOptions("build_options", options);
    if (httpz) |m| root.addImport("kzig_httpz", m);
    const exe = b.addExecutable(.{ .name = if (httpz != null) "bench-httpz" else "bench-std", .root_module = root });
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}

/// Test results are cached by binary, not environment: with an integration
/// server configured they always run, or a run without one would stand in.
fn runTests(b: *std.Build, t: *std.Build.Step.Compile) *std.Build.Step {
    // The configure step is cached too and doesn't see environment reads.
    b.graph.poisonCache();
    const run = b.addRunArtifact(t);
    for ([_][]const u8{ "DATABASE_URL", "S3_TEST_ENDPOINT" }) |name| {
        if (b.graph.environ_map.get(name) != null) run.has_side_effects = true;
    }
    return &run.step;
}

const examples = [_][]const u8{"task-api"};

const compile_errors = [_][2][]const u8{
    .{ "missing_service", "repo: no service" },
    .{ "upload_and_body", "reads both 'body' and 'upload'" },
    .{ "bad_cron", "invalid cron expression \"61 * * * *\"" },
    .{ "pointer_to_non_service", "alloc: no service" },
    .{ "field_without_default", "count needs a default or a service type" },
    .{ "dependency_cycle", "dependency cycle: " },
    .{ "unknown_handler", "has no handler lst" },
    .{ "duplicate_route", "duplicate route GET /api/v1/x/:key" },
    .{ "override_outside_test", "App overrides are only allowed in tests" },
    .{ "db_unknown_reference", "tasks.projectId: no table nope" },
    .{ "db_unknown_index_column", "users.indexes.nameIdx: no column fullName" },
    .{ "db_unknown_column_option", "users.email: no option .notNull" },
    .{ "db_where_wrong_type", "people.name: expects []const u8, got comptime_int" },
    .{ "db_unknown_column_in_query", "people: no column nickname" },
    .{ "db_upsert_unknown_update", "people: no column nmae" },
    .{ "db_upsert_empty_target", "people: upsert needs a target" },
    .{ "db_find_or_create_unknown", "people.nmae: no such column for findOrCreate's create" },
    .{ "db_find_or_create_no_where", "people: findOrCreate needs a where" },
    .{ "db_compare_column_types", "people.role and people.name: compares role with []const u8" },
    .{ "db_index_option", "t.indexes.n: no option .uniqe" },
    .{ "db_constraint_key", "t: no constraint kind .check (indexes, checks, primary_key)" },
    .{ "db_schema_duplicate_name", "two adapters bring a schema named \"main\"" },
    .{ "db_relation_no_inverse", "users.posts: no one back from posts and no single foreign key to users" },
    .{ "db_relation_alias", "users.name: a relation can't share a column's name" },
    .{ "db_relation_option", "posts.author: no option .refs" },
    .{ "db_with_unknown_relation", "users: no relation posts" },
    .{ "db_query_option", "users: no query option .whre (columns, where, orderBy, limit, offset, with)" },
    .{ "db_query_nested_option", "posts: no query option .limt (columns, where, orderBy, limit, offset, with)" },
    .{ "db_query_columns_mixed", "users: columns mixes true and false" },
    .{ "db_query_columns_none", "users: columns leaves out every column" },
    .{ "db_query_qualified_where", "users.name: a relational query names its own table's columns unqualified" },
    .{ "db_query_order_dir", "users: orderBy direction is .asc or .desc, not .DESC" },
    .{ "db_query_order_column", "users: no column nope" },
    .{ "db_relation_composite_through", "users.tags: through .from and .to take one column each" },
    .{ "db_relation_fields_length", "users.me: .fields and .references must be as long" },
    .{ "db_relation_many_fields", "users.tags: a many takes no .fields or .references" },
    .{ "db_enum_default", "t.r: default \"zzz\" is not a value of role" },
    .{ "unknown_module_option", "Module has no option .paths" },
    .{ "module_path_without_slash", "M: module path must be empty or start with '/'" },
    .{ "api_prefix_without_slash", "api_prefix must be empty or start with '/'" },
    .{ "contributor_missing", "GET /api/v1/x: the handler needs 'a' but no contributor on this route provides it" },
    .{ "contributor_cycle", "GET /api/v1/x: contributor cycle a -> b -> a" },
    .{ "contributor_duplicate", "GET /api/v1/x: contributor key 'a' registered twice" },
    .{ "contributor_optional_as_required", "'a' is optional; the handler must declare it as ?u32" },
    .{ "contributor_wrong_type", "'a' is u32, not []const u8 (in the handler)" },
    .{ "list_query_zero_limit", "ListQuery: limits must be at least 1 and default_limit <= max_limit" },
    .{ "adapter_cycle", "adapter cycle: " },
    .{ "adapter_missing_dependency", "which is not an adapter of this app" },
    .{ "bad_middleware", "GET /api/v1/x: middleware must be fn (*Ctx, *Next) !void or a type with handle" },
};
