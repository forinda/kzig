//! KickJS's `@forinda/kickjs-swagger`: an OpenAPI 3.0.3 spec at
//! `/openapi.json`, Swagger UI at `/docs` and ReDoc at `/redoc`, built from
//! the app's own types. Mount with `.plugins = &.{kzig.swagger.Plugin(.{ … })}`.
const std = @import("std");
const app = @import("app.zig");
const openapi = @import("openapi.zig");
const Ctx = @import("context.zig").Ctx;
const adapter = @import("adapter.zig");

pub const Server = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const Options = struct {
    info: struct {
        title: []const u8 = "API",
        version: []const u8 = "1.0.0",
        description: ?[]const u8 = null,
    } = .{},
    /// Listed before the server the app is listening on.
    servers: []const Server = &.{},
    /// Adds the `BearerAuth` scheme; routes opt in with `.docs = .{ .bearer_auth = true }`
    /// (or a controller's `docs`).
    bearer_auth: bool = false,
    docs_path: []const u8 = "/docs",
    redoc_path: []const u8 = "/redoc",
    spec_path: []const u8 = "/openapi.json",
    /// Answer 404 unless `NODE_ENV` is development or test.
    disable_in_prod: bool = false,
};

/// Swagger as a plugin: an adapter collecting every route's doc (KickJS
/// `registerControllerForDocs`) and a module serving the spec and the UIs.
pub fn Plugin(comptime options: Options) type {
    const Collector = struct {
        const Self = @This();

        process: *const app.Process,
        mutex: std.Io.Mutex = .init,
        docs: std.ArrayList(*const openapi.RouteDoc) = .empty,
        port: ?u16 = null,
        spec: ?[]u8 = null,

        pub fn onRouteMount(self: *Self, info: adapter.RouteInfo) void {
            const doc = info.doc orelse return;
            if (doc.exclude) return;
            self.docs.append(self.process.gpa, doc) catch std.log.err("swagger: out of memory; {s} {s} left out", .{ doc.method, doc.path });
        }

        /// The server the app listens on goes in `servers`.
        pub fn afterStart(self: *Self, info: adapter.StartInfo) void {
            self.mutex.lockUncancelable(self.process.io);
            defer self.mutex.unlock(self.process.io);
            self.port = info.port;
            self.dropSpec();
        }

        pub fn deinit(self: *Self) void {
            self.docs.deinit(self.process.gpa);
            self.dropSpec();
        }

        fn dropSpec(self: *Self) void {
            if (self.spec) |s| self.process.gpa.free(s);
            self.spec = null;
        }

        /// Built on first use and kept; copied into `arena` for the response.
        fn specJson(self: *Self, arena: std.mem.Allocator) ![]const u8 {
            self.mutex.lockUncancelable(self.process.io);
            defer self.mutex.unlock(self.process.io);
            if (self.spec == null) self.spec = try self.build();
            return arena.dupe(u8, self.spec.?);
        }

        fn build(self: *Self) ![]u8 {
            const gpa = self.process.gpa;
            var out: std.Io.Writer.Allocating = .init(gpa);
            errdefer out.deinit();
            const w = &out.writer;
            try w.writeAll(comptime info_json);
            try w.writeAll(",\"servers\":[");
            for (options.servers, 0..) |srv, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.value(srv, .{ .emit_null_optional_fields = false }, w);
            }
            if (self.port) |port| try w.print("{s}{{\"url\":\"http://localhost:{d}\"}}", .{ if (options.servers.len > 0) "," else "", port });

            try w.writeAll("],\"tags\":[");
            var seen: std.ArrayList([]const u8) = .empty;
            defer seen.deinit(gpa);
            var bearer = options.bearer_auth;
            for (self.docs.items) |d| {
                bearer = bearer or d.bearer_auth;
                for (d.tags) |t| {
                    if (contains(seen.items, t)) continue;
                    if (seen.items.len > 0) try w.writeByte(',');
                    try seen.append(gpa, t);
                    try w.writeAll("{\"name\":");
                    try std.json.Stringify.value(t, .{}, w);
                    try w.writeByte('}');
                }
            }

            // One entry per path, its operations together.
            try w.writeAll("],\"paths\":{");
            var done: std.ArrayList([]const u8) = .empty;
            defer done.deinit(gpa);
            for (self.docs.items) |d| {
                if (contains(done.items, d.path)) continue;
                if (done.items.len > 0) try w.writeByte(',');
                try done.append(gpa, d.path);
                try std.json.Stringify.value(d.path, .{}, w);
                try w.writeAll(":{");
                var first = true;
                for (self.docs.items) |e| {
                    if (!std.mem.eql(u8, e.path, d.path)) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("\"{s}\":{s}", .{ e.method, e.operation });
                }
                try w.writeByte('}');
            }
            try w.writeAll("},\"components\":{\"schemas\":{\"ProblemDetails\":" ++ openapi.problem_schema ++ "},\"securitySchemes\":{");
            if (bearer) try w.writeAll("\"BearerAuth\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}");
            try w.writeAll("}}}");
            return out.toOwnedSlice();
        }

        const info_json = "{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"" ++ openapi.escape(options.info.title) ++
            "\",\"version\":\"" ++ openapi.escape(options.info.version) ++ "\"" ++
            (if (options.info.description) |d| ",\"description\":\"" ++ openapi.escape(d) ++ "\"" else "") ++ "}";
    };

    const Docs = struct {
        const Self = @This();
        pub const docs = .{ .exclude = true };
        pub const routes = .{
            .{ .method = .GET, .path = options.spec_path, .handler = "spec" },
            .{ .method = .GET, .path = options.docs_path, .handler = "swaggerUi" },
            .{ .method = .GET, .path = options.redoc_path, .handler = "redoc" },
        };

        collector: *Collector,
        process: *const app.Process,

        pub fn spec(self: *Self, ctx: *Ctx) !Raw {
            try self.allowed();
            return .{ .content_type = "application/json", .body = try self.collector.specJson(ctx.arena) };
        }
        pub fn swaggerUi(self: *Self, _: *Ctx) !Raw {
            try self.allowed();
            return .{ .content_type = "text/html; charset=utf-8", .body = comptime swaggerHtml(options) };
        }
        pub fn redoc(self: *Self, _: *Ctx) !Raw {
            try self.allowed();
            return .{ .content_type = "text/html; charset=utf-8", .body = comptime redocHtml(options) };
        }

        fn allowed(self: *Self) !void {
            if (options.disable_in_prod and !self.process.dev_or_test) return error.NotFound;
        }
    };

    return app.Plugin(.{
        .name = "SwaggerPlugin",
        .modules = &.{app.Module(.{ .name = "SwaggerModule", .controllers = &.{Docs}, .prefix = false, .version = false })},
        .adapters = &.{Collector},
    });
}

/// A body sent as is, with its content type.
const Raw = struct {
    content_type: []const u8,
    body: []const u8,

    pub fn sendResponse(self: Raw, ctx: *Ctx) !void {
        try ctx.setHeader("content-type", self.content_type);
        ctx.res.body = self.body;
        ctx.res.sent = true;
    }
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn html(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| out = out ++ switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &[_]u8{c},
        };
        const result = out;
        return result;
    }
}

/// Swagger UI from unpkg, as KickJS falls back to without swagger-ui-dist.
fn swaggerHtml(comptime o: Options) []const u8 {
    return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n<title>" ++ html(o.info.title) ++ "</title>\n" ++
        "<link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\">\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n" ++
        "<script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\"></script>\n" ++
        "<script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js\"></script>\n" ++
        "<script>window.ui = SwaggerUIBundle({ url: \"" ++ openapi.escape(o.spec_path) ++ "\", dom_id: '#swagger-ui', deepLinking: true, " ++
        "presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset], layout: 'StandaloneLayout' });</script>\n</body>\n</html>\n";
}

/// ReDoc from jsdelivr.
fn redocHtml(comptime o: Options) []const u8 {
    return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n<title>" ++ html(o.info.title) ++ "</title>\n</head>\n<body>\n" ++
        "<redoc spec-url=\"" ++ html(o.spec_path) ++ "\"></redoc>\n" ++
        "<script src=\"https://cdn.jsdelivr.net/npm/redoc@2/bundles/redoc.standalone.js\"></script>\n</body>\n</html>\n";
}

const testing = std.testing;
const testing_rt = @import("testing.zig");

const Item = struct { id: u32, title: []const u8 };

const ItemsController = struct {
    pub const routes = .{
        .{ .method = .GET, .path = "/:id", .handler = "show", .docs = .{ .summary = "Get an item" } },
        .{ .method = .GET, .path = "/secret", .handler = "secret", .docs = .{ .exclude = true } },
    };
    pub fn show(_: *ItemsController, _: *Ctx, got: struct { params: struct { id: u32 } }) Item {
        return .{ .id = got.params.id, .title = "x" };
    }
    pub fn secret(_: *ItemsController, _: *Ctx) void {}
};

fn TestApp(comptime options: Options) type {
    return app.App(.{
        .modules = &.{app.Module(.{ .name = "ItemsModule", .path = "/items", .controllers = &.{ItemsController} })},
        .plugins = &.{Plugin(options)},
        .health = false,
    });
}

fn boot(comptime A: type, a: *A, node_env: ?[]const u8) !void {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    if (node_env) |e| try env.put("NODE_ENV", e);
    try a.init(testing.io, testing.allocator, &env);
}

test "openapi.json describes the app" {
    const A = TestApp(.{ .info = .{ .title = "Items API", .version = "2.0.0" }, .bearer_auth = true });
    var a: A = undefined;
    try boot(A, &a, "test");
    defer a.deinit();
    a.started(.{ .port = 4321 });
    var res = try testing_rt.request(testing.allocator, &a, .{ .target = "/openapi.json" });
    defer res.deinit();
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("application/json", res.header("content-type").?);
    const spec = try std.json.parseFromSliceLeaky(std.json.Value, res.arena.allocator(), res.body, .{});
    try testing.expectEqualStrings("3.0.3", spec.object.get("openapi").?.string);
    try testing.expectEqualStrings("Items API", spec.object.get("info").?.object.get("title").?.string);
    const paths = spec.object.get("paths").?.object;
    try testing.expect(paths.get("/api/v1/items/{id}").?.object.get("get") != null);
    try testing.expect(paths.get("/api/v1/items/secret") == null);
    try testing.expect(paths.get("/openapi.json") == null);
    try testing.expect(paths.get("/docs") == null);
    const components = spec.object.get("components").?.object;
    try testing.expect(components.get("schemas").?.object.get("ProblemDetails") != null);
    try testing.expectEqualStrings("bearer", components.get("securitySchemes").?.object.get("BearerAuth").?.object.get("scheme").?.string);
    try testing.expectEqualStrings("http://localhost:4321", spec.object.get("servers").?.array.items[0].object.get("url").?.string);
    try testing.expectEqualStrings("ItemsModule", spec.object.get("tags").?.array.items[0].object.get("name").?.string);
}

test "docs and redoc pages" {
    const A = TestApp(.{ .info = .{ .title = "Items <API>" } });
    var a: A = undefined;
    try boot(A, &a, "test");
    defer a.deinit();
    var docs = try testing_rt.request(testing.allocator, &a, .{ .target = "/docs" });
    defer docs.deinit();
    try testing.expectEqualStrings("text/html; charset=utf-8", docs.header("content-type").?);
    try testing.expect(std.mem.find(u8, docs.body, "swagger-ui-dist@5") != null);
    try testing.expect(std.mem.find(u8, docs.body, "\"/openapi.json\"") != null);
    try testing.expect(std.mem.find(u8, docs.body, "Items &lt;API&gt;") != null);
    var redoc = try testing_rt.request(testing.allocator, &a, .{ .target = "/redoc" });
    defer redoc.deinit();
    try testing.expect(std.mem.find(u8, redoc.body, "redoc") != null);
}

test "disable_in_prod hides the docs outside development and test" {
    const A = TestApp(.{ .disable_in_prod = true });
    var a: A = undefined;
    try boot(A, &a, null);
    defer a.deinit();
    for ([_][]const u8{ "/openapi.json", "/docs", "/redoc" }) |t| {
        var res = try testing_rt.request(testing.allocator, &a, .{ .target = t });
        defer res.deinit();
        try testing.expectEqual(std.http.Status.not_found, res.status);
    }
}
