//! kick/db's SQLite emitter: schema changes as SQLite DDL.
const std = @import("std");
const emit_pg = @import("emit_pg.zig");

const W = *std.Io.Writer;

/// A random version-4 UUID in canonical 8-4-4-4-12 form: SQLite has no uuid function.
const uuid_v4 = "(lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || " ++
    "substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))))";

/// The current time with milliseconds (CURRENT_TIMESTAMP has whole
/// seconds), as kick/db writes a `Date`.
const now = "(strftime('%Y-%m-%d %H:%M:%f', 'now'))";

/// kick/db's `sqliteDefault`: a Postgres-flavoured default as SQLite SQL.
pub fn formatDefault(w: W, value: []const u8, sql_type: []const u8, is_sql: bool) !void {
    const v = std.mem.trim(u8, value, " \t\r\n");
    // `.defaultSql()` is the caller's SQLite SQL, as written.
    if (is_sql) {
        const bare = emit_pg.isNumber(v) or (v.len > 0 and for (v) |ch| {
            if (!(std.ascii.isAlphabetic(ch) or ch == '_')) break false;
        } else true);
        return if (bare) w.writeAll(v) else w.print("({s})", .{v});
    }
    // A value on a text-like column, even `NULL` or `CURRENT_TIMESTAMP`.
    if (!emit_pg.allowsExpressionDefault(sql_type)) return emit_pg.literal(w, v);
    if (std.ascii.eqlIgnoreCase(v, "true")) return w.writeAll("1");
    if (std.ascii.eqlIgnoreCase(v, "false")) return w.writeAll("0");
    if (std.ascii.eqlIgnoreCase(v, "gen_random_uuid()") or std.ascii.eqlIgnoreCase(v, "uuid_generate_v4()")) return w.writeAll(uuid_v4);
    if (std.ascii.eqlIgnoreCase(v, "now()") or std.ascii.eqlIgnoreCase(v, "CURRENT_TIMESTAMP")) return w.writeAll(now);
    for ([_][]const u8{ "CURRENT_DATE", "CURRENT_TIME", "NULL" }) |kw| if (std.ascii.eqlIgnoreCase(v, kw)) return w.writeAll(kw);
    if (emit_pg.isNumber(v)) return w.writeAll(v);
    // A function call is an expression, which SQLite takes only in parentheses.
    if (emit_pg.isFunctionCall(v)) return w.print("({s})", .{v});
    return emit_pg.literal(w, v);
}
