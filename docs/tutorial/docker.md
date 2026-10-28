# 8. Docker

Zig builds a fully static binary for Linux with musl, so the image needs nothing but the binary
and the migrations: no distribution, no libc, no shell.

## Listen on every interface

Inside a container, `127.0.0.1` is the container itself. Add `HOST` to the config and pass it
to `serve`:

```zig title="src/config.zig"
//! Environment config. Each field reads its upper-cased name (`port` ←
//! `PORT`); a bad or missing value stops boot with every problem listed.
//! How the app runs (`KZIG_ENV`: development, test, production) is
//! `*const kzig.Process`'s `env`.
pub const Config = struct {
    port: u16 = 3000,
    /// `0.0.0.0` in a container, so traffic from outside it reaches the app.
    host: []const u8 = "127.0.0.1",
    log_level: []const u8 = "info",
};
```

```zig
// src/main.zig
const config = app.get(Config);
try kzig.runtime.std.serve(App, &app, init.io, init.gpa, .{ .host = config.host, .port = config.port });
```

## The Dockerfile

```dockerfile title="Dockerfile"
# Build a static binary, then ship only it and the migrations.
FROM alpine:3.20 AS build
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.17.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && ln -s /opt/zig-*/zig /usr/local/bin/zig
WORKDIR /src
# Dependencies first: this layer is reused until build.zig.zon changes.
COPY build.zig build.zig.zon ./
RUN zig build --fetch
COPY src src
RUN zig build -Doptimize=ReleaseSafe -Dtarget=$(uname -m)-linux-musl

FROM scratch
COPY --from=build /src/zig-out/bin/bookmarks /bookmarks
COPY db/migrations /db/migrations
ENV KZIG_ENV=production HOST=0.0.0.0 PORT=3000 \
    DB_FILE=/data/bookmarks.db MIGRATIONS_DIR=/db/migrations MIGRATE_ON_BOOT=true
VOLUME /data
EXPOSE 3000
ENTRYPOINT ["/bookmarks"]
```

```text
# .dockerignore
zig-out
.zig-cache
data
```

The build stage downloads Zig, fetches the dependencies in their own layer (reused until
`build.zig.zon` changes), and builds for `<arch>-linux-musl`. The final image starts `FROM
scratch`. The database lives in the `/data` volume; migrations apply when the container starts.

## Build and run

```console
$ docker build -t bookmarks .
$ docker images bookmarks
REPOSITORY   TAG       SIZE
bookmarks    latest    25.4MB
$ docker run -d --name bookmarks -p 3000:3000 \
    -e API_KEY=$(openssl rand -hex 24) -v bookmarks-data:/data bookmarks
$ docker logs bookmarks
info: migration 20261028_024358_init applied
info: listening on http://0.0.0.0:3000
```

```console
$ curl localhost:3000/health/ready
{"status":"ready","checks":[{"name":"sqlite","status":"up"}]}
$ docker restart bookmarks     # drains, stops, starts; the bookmarks stay in the volume
```

Swagger UI is at <http://localhost:3000/docs>.

!!! note "One container per database file"
    SQLite takes one writer at a time, and the file lives in this container's volume: run one
    replica. To run several, move the data to Postgres (`postgres://` in the pool's URL, a
    schema without `.dialect = .sqlite`), or to Turso or D1 over HTTP; see
    [SQLite, Turso and D1](../database/sqlite.md).

That's the whole app: a schema, a migration, a module, a guard, Swagger UI, tests and an image.
The [guides](../guide/modules.md) go deeper into each part.
