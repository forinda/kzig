# Tutorial: a bookmarks API

This tutorial builds a small, complete service from an empty folder: a JSON API that saves
links. By the end it has a SQLite database with migrations, validation, an API key on the
writes, Swagger UI, tests, a production build and a Docker image.

| Chapter | You add |
| --- | --- |
| [1. Set up](setup.md) | Zig, the `kzig` CLI, a new app that answers `/api/v1/hello` |
| [2. A first module](first-module.md) | `/api/v1/bookmarks`, generated: list, get, create, update, delete |
| [3. A database](database.md) | SQLite: a schema, a migration, a repository on the query builder |
| [4. An API key](api-key.md) | A setting, a guard on the writes, production refusing to start without the key |
| [5. API docs](swagger.md) | Swagger UI with an Authorize button, in production too |
| [6. Tests](tests.md) | The whole pipeline in-process, on a fresh database per test |
| [7. Production](production.md) | A release build, its settings, and how it shuts down |
| [8. Docker](docker.md) | A 25 MB image from a static binary, with the database on a volume |

Every command and file here was run as written. The finished app's routes:

| Method | Path | Key | Answers |
| --- | --- | --- | --- |
| `GET` | `/api/v1/bookmarks?q=&page=&limit=&sort=` | | 200, a page |
| `GET` | `/api/v1/bookmarks/:id` | | 200, or 404 |
| `POST` | `/api/v1/bookmarks` | yes | 201, 401, 409 (URL saved already), 422 |
| `PATCH` | `/api/v1/bookmarks/:id` | yes | 200, 401, 404, 422 |
| `DELETE` | `/api/v1/bookmarks/:id` | yes | 204, 401, 404 |
| `GET` | `/health/live`, `/health/ready`, `/docs` | | |
