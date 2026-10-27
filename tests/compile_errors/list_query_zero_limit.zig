const kzig = @import("kzig");
const Q = kzig.ListQuery(.{ .max_limit = 0 });
comptime {
    _ = Q.parse;
}
