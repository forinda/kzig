//! kzig — KickJS for Zig. The public API is re-exported from here as milestones land.

test {
    @import("std").testing.refAllDecls(@This());
}
