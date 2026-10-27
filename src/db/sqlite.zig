//! Local SQLite files (`sqlite:./app.db`, `sqlite::memory:`) through SQLite's
//! C library, built only with `-Dsqlite`.
const std = @import("std");
const c = @import("sqlite3");

test "the linked SQLite has RETURNING (3.35+)" {
    try std.testing.expect(c.sqlite3_libversion_number() >= 3_035_000);
}
