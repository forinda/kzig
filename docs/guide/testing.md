# Testing

`kzig.testing.request` runs the full pipeline in-process, no socket:

```zig
test "GET /api/v1/hello returns a greeting" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var app: App = undefined;
    try app.init(testing.io, testing.allocator, &env);
    defer app.deinit();

    var res = try kzig.testing.request(testing.allocator, &app, .{ .target = "/api/v1/hello" });
    defer res.deinit();
    try testing.expectEqual(.ok, res.status);
    const body = try res.json(struct { message: []const u8 });
    try testing.expectEqualStrings("Hello World from kzig!", body.message);
}
```

Replace a service in a test with `app.initWith(io, gpa, &env, .{FakeRepo{ … }})` — KickJS's
`createTestApp({ overrides })`; outside tests it doesn't compile.
