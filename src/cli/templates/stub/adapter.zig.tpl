const kzig = @import("kzig");

/// Add it to the App's `.adapters`. Every hook is optional.
pub const {{Pascal}}Adapter = struct {
    process: *const kzig.Process,

    pub fn beforeMount(_: *{{Pascal}}Adapter) !void {}

    pub fn afterStart(_: *{{Pascal}}Adapter, info: kzig.StartInfo) void {
        _ = info;
    }

    pub fn onHealthCheck(_: *{{Pascal}}Adapter) kzig.HealthCheck {
        return .{ .name = "{{Pascal}}Adapter", .status = .up };
    }

    pub fn shutdown(_: *{{Pascal}}Adapter) void {}
};
