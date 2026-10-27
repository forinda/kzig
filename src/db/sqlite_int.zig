//! SQLite drivers' parameter rule, shared by the local and HTTP ones.
const std = @import("std");

/// `0`, or `-?[1-9][0-9]*` within i64: bound as an INTEGER (so `LIMIT ?1`
/// and integer comparisons work). A TEXT column's affinity turns it back into
/// the same text; `007` or `+1` stay text.
pub fn canonicalInt(v: []const u8) ?i64 {
    if (v.len == 0 or v.len > 20) return null;
    const digits = if (v[0] == '-') v[1..] else v;
    if (digits.len == 0 or (digits[0] == '0' and (digits.len > 1 or v[0] == '-'))) return null;
    for (digits) |d| if (!std.ascii.isDigit(d)) return null;
    return std.fmt.parseInt(i64, v, 10) catch null;
}
