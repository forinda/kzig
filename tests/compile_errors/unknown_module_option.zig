const kzig = @import("kzig");
const M = kzig.Module(.{ .name = "M", .paths = "/x" });
comptime {
    _ = M.path;
}
