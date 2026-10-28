# 3. A database

The bookmarks go into a SQLite file. SQLite's C library is part of kzig, built only when asked
for, so turn it on where `build.zig` adds the dependency:

```zig
// build.zig
// .sqlite: SQLite's C library, for the local database file.
const kzig = b.dependency("kzig", .{ .target = target, .optimize = optimize, .sqlite = true });
```

## The schema

Tables are Zig struct literals. A wrong column name, or a value of the wrong type, anywhere a
query uses this table is a compile error.

```zig title="src/db/schema.zig"
const db = @import("kzig").db;

pub const bookmarks = db.table("bookmarks", .{
    .id = .{ .type = .serial, .primary_key = true },
    .url = .{ .type = .{ .varchar = 2048 }, .not_null = true, .unique = true },
    .title = .{ .type = .{ .varchar = 200 }, .not_null = true },
    .notes = .{ .type = .text },
    .createdAt = .{ .type = .timestamp, .not_null = true, .default = .now },
}, .{});

pub const Schema = db.Schema(.{ .bookmarks = bookmarks }, .{ .dialect = .sqlite });
```

## The database service

One SQLite file for the app, opened at boot. `DbSettings` reads `DB_FILE`, `MIGRATIONS_DIR` and
`MIGRATE_ON_BOOT` from the environment, with these defaults:

```zig title="src/db/database.zig"
const std = @import("std");
const kzig = @import("kzig");
const Schema = @import("schema.zig").Schema;

pub const Client = kzig.db.Client(Schema);

/// `DB_FILE`, `MIGRATIONS_DIR`, `MIGRATE_ON_BOOT`.
pub const DbSettings = struct {
    db_file: []const u8 = "data/bookmarks.db",
    migrations_dir: []const u8 = "db/migrations",
    /// Apply pending migrations at boot in production too (one instance).
    migrate_on_boot: bool = false,
};

/// One SQLite file for the app.
pub const Database = struct {
    process: *const kzig.Process,
    settings: *const DbSettings,
    pool: kzig.db.Pool = undefined,

    pub fn init(self: *Database) !void {
        const file = self.settings.db_file;
        if (!std.mem.eql(u8, file, ":memory:")) if (std.fs.path.dirname(file)) |dir|
            try std.Io.Dir.cwd().createDirPath(self.process.io, dir);
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        self.pool = try .init(self.process.io, self.process.gpa, .{ .url = try std.fmt.bufPrint(&buf, "sqlite:{s}", .{file}) });
    }

    pub fn deinit(self: *Database) void {
        self.pool.deinit();
    }

    pub fn client(self: *Database) Client {
        return .init(.{ .pool = &self.pool });
    }
};
```

## Migrations at boot

An adapter hooks into the app's lifecycle. This one applies pending migrations before the app
starts listening (in development and test, or when `MIGRATE_ON_BOOT=true`), refuses to start
with one pending otherwise, and reports the database on `/health/ready`. `db_name` and
`db_schema` tell `kzig db generate` which schema it writes migrations for.

```zig title="src/adapters/db.adapter.zig"
const kzig = @import("kzig");
const database = @import("../db/database.zig");

/// Migrations at boot (development and test, or with MIGRATE_ON_BOOT);
/// elsewhere a pending one stops the boot. `sqlite` on /health/ready.
pub const DbAdapter = struct {
    /// What `kzig db generate` writes migrations for.
    pub const db_name = "sqlite";
    pub const db_schema = @import("../db/schema.zig").Schema;

    database: *database.Database,
    settings: *const database.DbSettings,
    process: *const kzig.Process,

    pub fn beforeStart(self: *DbAdapter) !void {
        try kzig.db.migrate.onBoot(&self.database.pool, self.process.io, self.process.gpa, self.settings.migrations_dir, .{
            .on_boot = if (self.process.dev_or_test or self.settings.migrate_on_boot) .apply else .fail_if_pending,
        });
    }

    pub fn onHealthCheck(self: *DbAdapter) kzig.HealthCheck {
        self.database.pool.ping() catch return .{ .name = "sqlite", .status = .down };
        return .{ .name = "sqlite", .status = .up };
    }
};
```

Mount it on the App, and list the service and its settings in the module:

```zig
// src/main.zig
const DbAdapter = @import("adapters/db.adapter.zig").DbAdapter;

pub const App = kzig.App(.{
    .modules = modules,
    .config = Config,
    .adapters = &.{DbAdapter},
    …
});
```

```zig
// src/modules/bookmarks/bookmark.module.zig
const database = @import("../../db/database.zig");

pub const BookmarkModule = kzig.Module(.{
    .name = "BookmarkModule",
    .path = "/bookmarks",
    .controllers = &.{BookmarkController},
    .services = &.{ BookmarkService, BookmarkRepository, database.Database },
    .settings = &.{database.DbSettings},
});
```

Now write the first migration. `kzig db generate` builds the app, reads its schema, and diffs it
against the last migration (none yet):

```console
$ kzig db generate init
  zig build
  create db/migrations/20261028_024358_init/up.sql
  create db/migrations/20261028_024358_init/down.sql
  create db/migrations/20261028_024358_init/snapshot.json
  create db/migrations/20261028_024358_init/meta.json
2 change(s). Review it; `kzig db migrate` or the app at boot (kzig.db.migrate.onBoot) applies it
```

```sql title="db/migrations/20261028_024358_init/up.sql"
-- Generated by kzig vdev — review state lives in meta.json
CREATE TABLE "bookmarks" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "url" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "notes" TEXT,
  "createdAt" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now'))
);
CREATE UNIQUE INDEX "bookmarks_url_unique" ON "bookmarks" ("url");
```

Change the schema later and run `kzig db generate <name>` again: the new migration holds only
the difference. `kzig db check` fails in CI when the schema has changes no migration holds.

## The repository

The repository now speaks SQL through the query builder. The DTOs move here too, since they
follow the table: a bookmark has a `url`, a `title` and optional `notes`. `Bookmark` is the
table's own row type.

```zig title="src/modules/bookmarks/bookmark.repository.zig"
const std = @import("std");
const kzig = @import("kzig");
const db = kzig.db;
const Schema = @import("../../db/schema.zig").Schema;
const Database = @import("../../db/database.zig").Database;
const constants = @import("bookmark.constants.zig");

/// A row as the table holds it: `id`, `url`, `title`, `notes`, `createdAt`.
pub const Bookmark = Schema.Table(.bookmarks).Row;

pub const CreateBookmark = struct {
    url: []const u8,
    title: []const u8,
    notes: ?[]const u8 = null,

    pub fn validate(self: *const CreateBookmark, issues: *kzig.Issues) !void {
        if (!std.mem.startsWith(u8, self.url, "https://") and !std.mem.startsWith(u8, self.url, "http://"))
            try issues.add("url", "must start with http:// or https://");
        if (self.url.len > 2048) try issues.add("url", "must be at most 2048 characters");
        try checkTitle(self.title, issues);
    }
};

pub const UpdateBookmark = struct {
    title: ?[]const u8 = null,
    notes: ?[]const u8 = null,

    pub fn validate(self: *const UpdateBookmark, issues: *kzig.Issues) !void {
        if (self.title) |title| try checkTitle(title, issues);
    }
};

fn checkTitle(title: []const u8, issues: *kzig.Issues) !void {
    if (title.len == 0 or title.len > 200) try issues.add("title", "must be 1 to 200 characters");
}

pub const BookmarkPage = struct { rows: []const Bookmark, total: usize };

/// The `bookmarks` table, through kzig.db's query builder.
pub const BookmarkRepository = struct {
    database: *Database,

    pub fn findAll(self: *BookmarkRepository, arena: std.mem.Allocator, query: constants.Query) !BookmarkPage {
        const client = self.database.client();
        // `?q=` searches titles; LIKE's own wildcards in it are escaped.
        const pattern = try std.fmt.allocPrint(arena, "%{s}%", .{try db.escapeLike(arena, query.search)});
        const matching = client.selectFrom(.bookmarks).whereExpr(db.like(.title, pattern));
        const oldest_first = query.sort.len > 0 and query.sort[0].direction == .asc;
        const rows = if (oldest_first)
            try matching.orderBy(.createdAt, .asc).orderBy(.id, .asc).limit(query.limit).offset(query.offset).execute(arena)
        else
            try matching.orderBy(.createdAt, .desc).orderBy(.id, .desc).limit(query.limit).offset(query.offset).execute(arena);
        return .{ .rows = rows, .total = @intCast(try matching.count(arena)) };
    }

    pub fn findById(self: *BookmarkRepository, arena: std.mem.Allocator, id: i32) !?Bookmark {
        return self.database.client().selectFrom(.bookmarks).where(.id, .eq, id).executeTakeFirst(arena);
    }

    /// A URL saved twice is `error.Conflict`: 409.
    pub fn create(self: *BookmarkRepository, arena: std.mem.Allocator, input: CreateBookmark) !Bookmark {
        return self.database.client().insertInto(.bookmarks)
            .values(.{ .url = input.url, .title = input.title, .notes = input.notes })
            .returningAll().executeTakeFirstOrThrow(arena);
    }

    pub fn update(self: *BookmarkRepository, arena: std.mem.Allocator, id: i32, input: UpdateBookmark) !?Bookmark {
        return self.database.client().updateTable(.bookmarks)
            .set(.{ .title = input.title, .notes = input.notes })
            .where(.id, .eq, id).returningAll().executeTakeFirst(arena);
    }

    pub fn delete(self: *BookmarkRepository, arena: std.mem.Allocator, id: i32) !bool {
        return try self.database.client().deleteFrom(.bookmarks).where(.id, .eq, id).execute(arena) > 0;
    }
};
```

The list query keeps `q`, `sort`, `page` and `limit`; the generated filters go:

```zig title="src/modules/bookmarks/bookmark.constants.zig"
const kzig = @import("kzig");

/// `GET /bookmarks`: `q=` (title contains), `sort=createdAt` or
/// `sort=-createdAt` (the default, newest first), `page`, `limit`.
pub const Query = kzig.ListQuery(.{
    .sortable = &.{"createdAt"},
    .searchable = &.{"title"},
});
```

The service passes the request's arena along (rows are allocated in it, and freed with the
request), and turns a missing row into `error.NotFound`:

```zig title="src/modules/bookmarks/bookmark.service.zig"
const std = @import("std");
const repo = @import("bookmark.repository.zig");
const constants = @import("bookmark.constants.zig");

pub const BookmarkService = struct {
    repo: *repo.BookmarkRepository,

    pub fn list(self: *BookmarkService, arena: std.mem.Allocator, query: constants.Query) !repo.BookmarkPage {
        return self.repo.findAll(arena, query);
    }

    pub fn get(self: *BookmarkService, arena: std.mem.Allocator, id: i32) !repo.Bookmark {
        return try self.repo.findById(arena, id) orelse error.NotFound;
    }

    pub fn create(self: *BookmarkService, arena: std.mem.Allocator, input: repo.CreateBookmark) !repo.Bookmark {
        return self.repo.create(arena, input);
    }

    pub fn update(self: *BookmarkService, arena: std.mem.Allocator, id: i32, input: repo.UpdateBookmark) !repo.Bookmark {
        return try self.repo.update(arena, id, input) orelse error.NotFound;
    }

    pub fn remove(self: *BookmarkService, arena: std.mem.Allocator, id: i32) !void {
        if (!try self.repo.delete(arena, id)) return error.NotFound;
    }
};
```

In the controller, the handlers pass `ctx.arena` to the service, `Id` takes an `i32` (the
table's `serial`), and `list` no longer checks filter operators:

```zig
const Id = struct { id: i32 };

pub fn get(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { params: Id }) !repo.Bookmark {
    return self.service.get(ctx.arena, got.params.id);
}

pub fn create(self: *BookmarkController, ctx: *kzig.Ctx, got: struct { body: repo.CreateBookmark }) !void {
    try ctx.created(try self.service.create(ctx.arena, got.body));
}
```

(The full controller is in the [next chapter](api-key.md), with the API key added.)

## Try it

```console
$ KZIG_ENV=development zig build run
info: migration 20261028_024358_init applied
info: listening on http://127.0.0.1:3000
```

```console
$ curl -H 'content-type: application/json' \
    -d '{"url":"https://ziglang.org","title":"Zig","notes":"the language"}' localhost:3000/api/v1/bookmarks
{"id":1,"url":"https://ziglang.org","title":"Zig","notes":"the language","createdAt":"2026-10-28T02:44:13.367Z"}
$ curl -H 'content-type: application/json' -d '{"url":"https://ziglang.org","title":"again"}' localhost:3000/api/v1/bookmarks
{"type":"about:blank","title":"Conflict","status":409}
$ curl -H 'content-type: application/json' -d '{"url":"ftp://x","title":""}' localhost:3000/api/v1/bookmarks
{"type":"about:blank","title":"Unprocessable Entity","status":422,"detail":"must start with http:// or https://","errors":[{"field":"url","message":"must start with http:// or https://"},{"field":"title","message":"must be 1 to 200 characters"}]}
$ curl localhost:3000/health/ready
{"status":"ready","checks":[{"name":"sqlite","status":"up"}]}
```

Restart the app: the bookmarks are still there, in `data/bookmarks.db`. Anyone can write them,
though. Next, [an API key](api-key.md).
