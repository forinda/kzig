//! KickJS's list query (`ctx.qs` / `ctx.paginate`): `filter=field:op:value`
//! (repeatable), `sort=-created,title:asc`, `page`, `limit`, `q`. Bad input
//! is dropped or clamped, never an error — a list endpoint stays usable.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;

pub const Operator = enum { eq, neq, gt, gte, lt, lte, between, in, contains, starts, ends };
pub const Direction = enum { asc, desc };

pub const Filter = struct {
    field: []const u8,
    operator: Operator,
    value: []const u8,
};

pub const Sort = struct {
    field: []const u8,
    direction: Direction,
};

pub const Config = struct {
    /// Empty allows nothing (KickJS: no config allows everything; a list
    /// endpoint is safer closed).
    filterable: []const []const u8 = &.{},
    sortable: []const []const u8 = &.{},
    searchable: []const []const u8 = &.{},
    default_limit: u32 = 20,
    max_limit: u32 = 100,
    max_search: usize = 200,
};

pub fn Paginated(comptime T: type) type {
    return struct {
        data: []const T,
        meta: struct {
            page: u32,
            limit: u32,
            total: usize,
            totalPages: usize,
            hasNext: bool,
            hasPrev: bool,
        },
        links: struct {
            self: []const u8,
            next: ?[]const u8,
            prev: ?[]const u8,
        },
    };
}

/// Read as `got: struct { query: kzig.ListQuery(.{ … }) }`.
pub fn ListQuery(comptime cfg: Config) type {
    if (cfg.default_limit < 1 or cfg.max_limit < 1 or cfg.default_limit > cfg.max_limit)
        @compileError("ListQuery: limits must be at least 1 and default_limit <= max_limit");
    return struct {
        const Self = @This();
        pub const kzig_list_query = true;
        pub const config = cfg;

        filters: []const Filter,
        sort: []const Sort,
        page: u32,
        limit: u32,
        offset: u32,
        search: []const u8,

        pub fn parse(ctx: *Ctx) !Self {
            var filters: std.ArrayList(Filter) = .empty;
            for (try ctx.queryAll("filter")) |item| if (parseFilter(item)) |f| try filters.append(ctx.arena, f);

            var sort: std.ArrayList(Sort) = .empty;
            for (try ctx.queryAll("sort")) |param| {
                var it = std.mem.splitScalar(u8, param, ',');
                while (it.next()) |raw| if (parseSort(std.mem.trim(u8, raw, " "))) |s| try sort.append(ctx.arena, s);
            }

            var page = positive(try ctx.query("page")) orelse 1;
            var limit = positive(try ctx.query("limit")) orelse cfg.default_limit;
            if (limit > cfg.max_limit) limit = cfg.max_limit;
            // Keep offset in range for absurd pages.
            const max_page = std.math.maxInt(u32) / limit;
            if (page > max_page) page = max_page;

            const q = std.mem.trim(u8, (try ctx.query("q")) orelse "", " \t");
            return .{
                .filters = filters.items,
                .sort = sort.items,
                .page = page,
                .limit = limit,
                .offset = (page - 1) * limit,
                .search = if (cfg.searchable.len == 0) "" else utf8Prefix(q, cfg.max_search),
            };
        }

        /// `ctx.paginate`: data plus meta and links that keep the other
        /// query params, with `page` replaced.
        pub fn paginate(self: Self, ctx: *Ctx, comptime T: type, data: []const T, total: usize) !Paginated(T) {
            const total_pages = @max(1, std.math.divCeil(usize, total, self.limit) catch 1);
            const has_next = self.page < total_pages;
            const has_prev = self.page > 1;
            return .{
                .data = data,
                .meta = .{ .page = self.page, .limit = self.limit, .total = total, .totalPages = total_pages, .hasNext = has_next, .hasPrev = has_prev },
                .links = .{
                    .self = try pageLink(ctx, null),
                    .next = if (has_next) try pageLink(ctx, self.page + 1) else null,
                    .prev = if (has_prev) try pageLink(ctx, self.page - 1) else null,
                },
            };
        }

        fn parseFilter(item: []const u8) ?Filter {
            const a = std.mem.findScalar(u8, item, ':') orelse return null;
            const b = std.mem.findScalarPos(u8, item, a + 1, ':') orelse return null;
            const field = item[0..a];
            const value = item[b + 1 ..];
            if (field.len == 0 or value.len == 0) return null;
            const op = std.meta.stringToEnum(Operator, item[a + 1 .. b]) orelse return null;
            if (!allowed(cfg.filterable, field)) return null;
            return .{ .field = field, .operator = op, .value = value };
        }

        fn parseSort(item: []const u8) ?Sort {
            if (item.len == 0) return null;
            var field = item;
            var dir: Direction = .asc;
            if (std.mem.findScalarLast(u8, item, ':')) |c| {
                field = item[0..c];
                dir = if (std.ascii.eqlIgnoreCase(item[c + 1 ..], "asc")) .asc else if (std.ascii.eqlIgnoreCase(item[c + 1 ..], "desc")) .desc else return null;
            } else if (item[0] == '-') {
                field = item[1..];
                dir = .desc;
            } else if (item[0] == '+') field = item[1..];
            if (field.len == 0 or !allowed(cfg.sortable, field)) return null;
            return .{ .field = field, .direction = dir };
        }
    };
}

fn allowed(list: []const []const u8, field: []const u8) bool {
    for (list) |f| if (std.mem.eql(u8, f, field)) return true;
    return false;
}

fn positive(raw: ?[]const u8) ?u32 {
    const n = std.fmt.parseInt(u32, raw orelse return null, 10) catch return null;
    return if (n == 0) null else n;
}

/// At most `max` bytes, cut on a UTF-8 boundary.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

/// The request's path and query with `page` set to `page` (or as it is).
fn pageLink(ctx: *Ctx, page: ?u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.arena, ctx.req.path);
    var replaced = false;
    var first = true;
    var it = std.mem.splitScalar(u8, ctx.req.query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        try out.append(ctx.arena, if (first) '?' else '&');
        first = false;
        const key = pair[0 .. std.mem.findScalar(u8, pair, '=') orelse pair.len];
        if (page != null and std.mem.eql(u8, key, "page")) {
            try out.print(ctx.arena, "page={d}", .{page.?});
            replaced = true;
        } else try out.appendSlice(ctx.arena, pair);
    }
    if (page != null and !replaced) try out.print(ctx.arena, "{c}page={d}", .{ @as(u8, if (first) '?' else '&'), page.? });
    return out.items;
}

const testing = std.testing;

fn ctxFor(arena: std.mem.Allocator, req: *const @import("context.zig").Request, res: *@import("context.zig").Response) Ctx {
    return .{ .arena = arena, .req = req, .res = res };
}

const Q = ListQuery(.{ .filterable = &.{ "status", "title" }, .sortable = &.{ "created", "title" }, .searchable = &.{"title"} });

fn parseTarget(arena: std.mem.Allocator, path: []const u8, query: []const u8) !Q {
    const req = try arena.create(@import("context.zig").Request);
    req.* = .{ .method = .GET, .path = path, .query = query, .headers = &.{}, .body = "" };
    const res = try arena.create(@import("context.zig").Response);
    res.* = .{};
    var ctx = ctxFor(arena, req, res);
    return Q.parse(&ctx);
}

test "parses filters, sort, search" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const q = try parseTarget(arena.allocator(), "/tasks", "filter=status:eq:open&filter=title:contains:a%20b&sort=-created,title:asc&q=%20rocket%20&page=2&limit=5");
    try testing.expectEqual(2, q.filters.len);
    try testing.expectEqualStrings("status", q.filters[0].field);
    try testing.expectEqual(Operator.eq, q.filters[0].operator);
    try testing.expectEqualStrings("a b", q.filters[1].value);
    try testing.expectEqual(2, q.sort.len);
    try testing.expectEqualStrings("created", q.sort[0].field);
    try testing.expectEqual(Direction.desc, q.sort[0].direction);
    try testing.expectEqual(Direction.asc, q.sort[1].direction);
    try testing.expectEqualStrings("rocket", q.search);
    try testing.expectEqual(2, q.page);
    try testing.expectEqual(5, q.limit);
    try testing.expectEqual(5, q.offset);
}

test "drops bad filters and sorts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const q = try parseTarget(arena.allocator(), "/tasks", "filter=status:eq:&filter=status:like:x&filter=secret:eq:1&filter=nocolon&sort=secret,title:sideways");
    try testing.expectEqual(0, q.filters.len);
    try testing.expectEqual(0, q.sort.len);
}

test "clamps pagination" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try parseTarget(a, "/tasks", "limit=1000&page=0");
    try testing.expectEqual(100, big.limit);
    try testing.expectEqual(1, big.page);
    const junk = try parseTarget(a, "/tasks", "limit=x&page=abc");
    try testing.expectEqual(20, junk.limit);
    try testing.expectEqual(1, junk.page);
}

test "search is truncated to max_search" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const long: [300]u8 = @splat('a');
    const q = try parseTarget(arena.allocator(), "/tasks", "q=" ++ long);
    try testing.expectEqual(200, q.search.len);
}

test "paginate meta and links" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try a.create(@import("context.zig").Request);
    req.* = .{ .method = .GET, .path = "/api/v1/tasks", .query = "sort=-created&page=2&limit=2", .headers = &.{}, .body = "" };
    const res = try a.create(@import("context.zig").Response);
    res.* = .{};
    var ctx = ctxFor(a, req, res);
    const q = try Q.parse(&ctx);
    const page = try q.paginate(&ctx, u32, &.{ 3, 4 }, 5);
    try testing.expectEqual(3, page.meta.totalPages);
    try testing.expect(page.meta.hasNext and page.meta.hasPrev);
    try testing.expectEqualStrings("/api/v1/tasks?sort=-created&page=2&limit=2", page.links.self);
    try testing.expectEqualStrings("/api/v1/tasks?sort=-created&page=3&limit=2", page.links.next.?);
    try testing.expectEqualStrings("/api/v1/tasks?sort=-created&page=1&limit=2", page.links.prev.?);
    const json = try std.json.Stringify.valueAlloc(a, page, .{});
    try testing.expect(std.mem.startsWith(u8, json, "{\"data\":[3,4],\"meta\":{\"page\":2,\"limit\":2,\"total\":5,\"totalPages\":3,\"hasNext\":true,\"hasPrev\":true}"));
}
