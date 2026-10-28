# 4. An API key

Reads stay open; creating, changing and deleting need `Authorization: Bearer <API_KEY>`.

## The setting and the guard

A settings struct reads `API_KEY` from the environment when the module that lists it mounts.
`dev_defaults` apply only when `KZIG_ENV` is `development` or `test`, so production can't start
without a real key. The guard is middleware with a service's fields: the settings are injected.

```zig title="src/guards/api-key.guard.zig"
const std = @import("std");
const kzig = @import("kzig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// `API_KEY`: required in production; development and test get a default.
pub const AuthSettings = struct {
    pub const dev_defaults = .{ .api_key = "dev-api-key-change-me-0123456789ab" };
    api_key: []const u8,

    pub fn validate(self: *const AuthSettings, issues: *kzig.Issues) !void {
        if (self.api_key.len < 32) try issues.add("api_key", "must be at least 32 characters");
    }
};

/// `Authorization: Bearer <API_KEY>` or 401. The key is compared as a digest,
/// so the check takes the same time whatever was sent.
pub const ApiKeyGuard = struct {
    settings: *const AuthSettings,

    pub fn handle(self: *ApiKeyGuard, ctx: *kzig.Ctx, next: *kzig.Next) !void {
        const header = ctx.header("authorization") orelse "";
        const key = if (std.ascii.startsWithIgnoreCase(header, "Bearer ")) std.mem.trim(u8, header["Bearer ".len..], " ") else "";
        if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest(key), digest(self.settings.api_key)))
            return ctx.fail(.unauthorized, "Invalid API key");
        next.run();
    }
};

fn digest(s: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(s, &out, .{});
    return out;
}
```

List `AuthSettings` in the module beside `DbSettings`:

```zig
.settings = &.{ database.DbSettings, AuthSettings },
```

## On the routes that write

Middleware runs on the App, a controller, or a single route. Here it's the three writes:

```zig title="src/modules/bookmarks/bookmark.controller.zig"
const kzig = @import("kzig");
const repo = @import("bookmark.repository.zig");
const constants = @import("bookmark.constants.zig");
const BookmarkService = @import("bookmark.service.zig").BookmarkService;

const ApiKeyGuard = @import("../../guards/api-key.guard.zig").ApiKeyGuard;

const Id = struct { id: i32 };

pub const BookmarkController = struct {
    service: *BookmarkService,

    pub const docs = .{ .tags = &[_][]const u8{"Bookmarks"} };

    /// Writes need `Authorization: Bearer <API_KEY>`; reads are open.
    const key = .{ApiKeyGuard};

    pub const routes = .{
        .{ .method = .GET, .path = "/", .handler = "list", .docs = .{
            .summary = "List bookmarks",
            .responses = .{
                .{ .status = 200, .description = "A page of bookmarks", .body = kzig.Paginated(repo.Bookmark) },
            },
        } },
        .{ .method = .GET, .path = "/:id", .handler = "get", .docs = .{
            .summary = "Get a bookmark",
            .responses = .{ .{ .status = 200, .description = "The bookmark", .body = repo.Bookmark }, not_found },
        } },
        .{ .method = .POST, .path = "/", .handler = "create", .middleware = key, .docs = .{
            .summary = "Create a bookmark",
            .bearer_auth = true,
            .responses = .{
                .{ .status = 201, .description = "Created", .body = repo.Bookmark },
                .{ .status = 401, .description = "No or wrong API key" },
                .{ .status = 409, .description = "This URL is saved already" },
            },
        } },
        .{ .method = .PATCH, .path = "/:id", .handler = "update", .middleware = key, .docs = .{
            .summary = "Update a bookmark",
            .bearer_auth = true,
            .responses = .{ .{ .status = 200, .description = "The updated bookmark", .body = repo.Bookmark }, not_found },
        } },
        .{ .method = .DELETE, .path = "/:id", .handler = "remove", .middleware = key, .docs = .{
            .summary = "Delete a bookmark",
            .bearer_auth = true,
            .responses = .{ .{ .status = 204, .description = "Deleted" }, not_found },
        } },
    };
    const not_found = .{ .status = 404, .description = "No bookmark with this id" };

    pub fn list(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { query: constants.Query }) !kzig.Paginated(repo.Bookmark) {
        const page = try self.service.list(ctx.arena, got.query);
        return got.query.paginate(ctx, repo.Bookmark, page.rows, page.total);
    }

    pub fn get(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { params: Id }) !repo.Bookmark {
        return self.service.get(ctx.arena, got.params.id);
    }

    pub fn create(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { body: repo.CreateBookmark }) !void {
        try ctx.created(try self.service.create(ctx.arena, got.body));
    }

    pub fn update(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { params: Id, body: repo.UpdateBookmark }) !repo.Bookmark {
        return self.service.update(ctx.arena, got.params.id, got.body);
    }

    /// 204 when it returns.
    pub fn remove(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { params: Id }) !void {
        try self.service.remove(ctx.arena, got.params.id);
    }
};
```

```console
$ curl -H 'content-type: application/json' -d '{"url":"https://x.dev","title":"x"}' localhost:3000/api/v1/bookmarks
{"type":"about:blank","title":"Unauthorized","status":401,"detail":"Invalid API key"}
$ curl -H 'authorization: Bearer dev-api-key-change-me-0123456789ab' -H 'content-type: application/json' \
    -d '{"url":"https://x.dev","title":"x"}' localhost:3000/api/v1/bookmarks
{"id":2,"url":"https://x.dev","title":"x","notes":null,"createdAt":"…"}
```

Without `KZIG_ENV=development` there's no default key, and the app says so before it listens:

```console
$ zig build run
error: Config is invalid:
error:   API_KEY: required
```

Next, [API docs](swagger.md).
