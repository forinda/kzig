//! The SQLite schema is multi-tenant-kickdb-api's: its latest snapshot.json,
//! byte for byte.
const std = @import("std");
const kzig = @import("kzig");
const TenantSchema = @import("tenant.schema.zig").TenantSchema;

const testing = std.testing;

test "tenant schema: multi-tenant-kickdb-api's latest snapshot, byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/task-api/db/sqlite-migrations/20261016_220159_project_title_unique/snapshot.json", a, .limited(1 << 20));
    const ours = try kzig.db.snapshot.toJson(a, kzig.db.snapshot.fromSchema(TenantSchema));
    try testing.expectEqualStrings(std.mem.trimEnd(u8, text, "\n"), ours);
}
