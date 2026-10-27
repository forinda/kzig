.{
    .name = .{{snake}},
    .version = "0.0.1",
    .fingerprint = {{fingerprint}},
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
{{dependency}}    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
