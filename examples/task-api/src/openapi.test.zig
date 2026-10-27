//! The served spec is structurally sound: what the roadmap's acceptance
//! claims, checked on every run.
const std = @import("std");
const boot = @import("test_app.zig").boot;

const testing = std.testing;
const Value = std.json.Value;

fn eachRef(v: Value, spec: Value) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "$ref")) {
                    const prefix = "#/components/schemas/";
                    try testing.expect(std.mem.startsWith(u8, e.value_ptr.string, prefix));
                    const name = e.value_ptr.string[prefix.len..];
                    try testing.expect(spec.object.get("components").?.object.get("schemas").?.object.get(name) != null);
                } else try eachRef(e.value_ptr.*, spec);
            }
        },
        .array => |a| for (a.items) |x| try eachRef(x, spec),
        else => {},
    }
}

test "the OpenAPI spec is structurally sound" {
    const t = try boot(&.{});
    defer t.deinit();
    var res = try t.get("/openapi.json");
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const arena = res.arena.allocator();
    const spec = try std.json.parseFromSliceLeaky(Value, arena, res.body, .{});
    try testing.expectEqualStrings("3.0.3", spec.object.get("openapi").?.string);
    try eachRef(spec, spec);

    var tags: std.StringHashMapUnmanaged(void) = .empty;
    for (spec.object.get("tags").?.array.items) |tag| try tags.put(arena, tag.object.get("name").?.string, {});
    var ids: std.StringHashMapUnmanaged(void) = .empty;

    var paths = spec.object.get("paths").?.object.iterator();
    var operations: usize = 0;
    while (paths.next()) |p| {
        var methods = p.value_ptr.object.iterator();
        while (methods.next()) |m| {
            operations += 1;
            const op = m.value_ptr.object;
            // Unique operation ids.
            const id = op.get("operationId").?.string;
            try testing.expect(!ids.contains(id));
            try ids.put(arena, id, {});
            // Declared tags.
            for (op.get("tags").?.array.items) |tag| try testing.expect(tags.contains(tag.string));
            // Every `{param}` in the path is a required path parameter, and back.
            var declared: usize = 0;
            if (op.get("parameters")) |params| for (params.array.items) |param| {
                if (!std.mem.eql(u8, param.object.get("in").?.string, "path")) continue;
                declared += 1;
                try testing.expect(param.object.get("required").?.bool);
                const needle = try std.fmt.allocPrint(arena, "{{{s}}}", .{param.object.get("name").?.string});
                try testing.expect(std.mem.find(u8, p.key_ptr.*, needle) != null);
            };
            try testing.expectEqual(std.mem.count(u8, p.key_ptr.*, "{"), declared);
            // Responses: valid status keys with descriptions; nothing on 204.
            var responses = op.get("responses").?.object.iterator();
            while (responses.next()) |r| {
                const code = r.key_ptr.*;
                try testing.expect(std.mem.eql(u8, code, "default") or (code.len == 3 and code[0] >= '1' and code[0] <= '5'));
                try testing.expect(r.value_ptr.object.get("description") != null);
                if (std.mem.eql(u8, code, "204")) try testing.expect(r.value_ptr.object.get("content") == null);
            }
        }
    }
    try testing.expect(operations >= 9);
}
