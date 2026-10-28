# The kzig CLI

Prebuilt `kzig` binaries for Linux and macOS are attached to each
[release](https://github.com/forinda/kzig/releases) (on macOS, a browser download needs
`xattr -d com.apple.quarantine kzig`); or build it:

```console
$ zig build                  # builds zig-out/bin/kzig
$ kzig new my-api            # an App with a hello module, tests and Swagger; fetches kzig
$ cd my-api && zig build test
$ kzig dev                   # zig build + run; rebuilds and restarts on change
$ kzig g module task         # src/modules/tasks: REST CRUD with an in-memory repository and tests
$ kzig g middleware audit    # also: controller, service, contributor, adapter, dto, guard, test
$ kzig add httpz             # serve on http.zig; `kzig add swagger` puts Swagger back
$ kzig build                 # zig build -Doptimize=ReleaseSafe
$ kzig start --port 8080     # the built app, NODE_ENV=production
$ kzig rm module task
$ kzig db migrate            # see Database
```

`kzig g module` writes KickJS's REST module — `GET /` (filter/sort/page), `GET /:id`, `POST /`
(201), `PATCH /:id`, `DELETE /:id` (204) — and mounts it. Filters on `name` take `eq`, `neq`,
`contains`, `starts` and `ends`; another operator is a 400. task-api's `tasks` module was
generated this way.

`kzig dev` watches `src/`, `build.zig` and `build.zig.zon`, sets `NODE_ENV=development` unless
it is set, and passes arguments after `--` to the app. A build that fails leaves the running app
up; Ctrl-C stops both. `kzig start` replaces itself with the app, so a supervisor's SIGTERM
reaches the app and it drains. Names may be any case (`TaskList`, `task_list`, `HTTPClient`);
plurals know the irregular words (`person` → `people`).
