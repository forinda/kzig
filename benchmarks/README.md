# Benchmarks

`run.sh` serves the same routes from:

- **kzig std** and **kzig http.zig**: [`bench.zig`](./bench.zig), minimal-api's hello module plus the
  three routes of KickJS's own `scripts/benchmark.js`, with `requestId` and `helmet` middleware,
  built `ReleaseFast`;
- **KickJS minimal-api**: the real app from
  [kickjs-examples-archive](https://github.com/forinda/kickjs-examples-archive) on Express,
  `NODE_ENV=production`;
- **Express**: the app from KickJS's `scripts/benchmark.js` (`express.json()`, zod validation),
  [`express-baseline.cjs`](./express-baseline.cjs).

Each route: 2 s warm-up, then [autocannon](https://github.com/mcollina/autocannon) for 10 s with 100
connections and 4 workers, on the same machine as the server.

```console
$ ./benchmarks/run.sh   # needs ../kick-js (autocannon, express, zod) and ../kickjs-examples-archive
```

## Results

AMD Ryzen 5 5600G (6 cores / 12 threads), 37 GB RAM, Linux 7.0, Zig 0.17.0, Node 24.20.0.

| server | route | req/s | avg ms | p99 ms | non-2xx |
| --- | --- | ---: | ---: | ---: | ---: |
| kzig std | /api/v1/hello | 115,930 | 0.18 | 2 | 0 |
| kzig std | /api/v1/json | 74,808 | 0.77 | 3 | 0 |
| kzig std | /api/v1/echo/42 | 82,042 | 0.61 | 4 | 0 |
| kzig std | /api/v1/validate | 103,002 | 0.3 | 2 | 0 |
| kzig http.zig | /api/v1/hello | 124,032 | 0.17 | 2 | 0 |
| kzig http.zig | /api/v1/json | 138,609 | 0.08 | 1 | 0 |
| kzig http.zig | /api/v1/echo/42 | 134,192 | 0.1 | 1 | 0 |
| kzig http.zig | /api/v1/validate | 58,799 | 1.16 | 7 | 0 |
| KickJS minimal-api (Express) | /api/v1/hello | 5,292 | 18.41 | 47 | 0 |
| Express (KickJS benchmark app) | /api/v1/json | 9,296 | 10.27 | 23 | 0 |
| Express (KickJS benchmark app) | /api/v1/echo/42 | 8,445 | 11.35 | 25 | 0 |
| Express (KickJS benchmark app) | /api/v1/validate | 9,487 | 10.06 | 28 | 0 |

## Route matching

`zig build bench-router -Doptimize=ReleaseFast && ./zig-out/bin/bench-router`: 500 routes
(100 REST resources), matching alone, no socket. Same machine as above.

| request | linear scan (≤ v0.1.0) | segment tree |
| --- | ---: | ---: |
| first route | 72–87 ns | 101–103 ns |
| middle | 254–296 ns | 102–103 ns |
| last | 482–681 ns | 104–153 ns |
| miss (404, `Allow` checked) | 3,568–4,046 ns | 292–385 ns |

## Reading them

- **kzig vs KickJS**: 6–23× the requests at a tenth of the latency or less, on every route
  (slowest pairing: http.zig's `/validate`, 6.2× Express's). The real KickJS app (DI, middleware,
  return-value handlers) is about half as fast as the bare Express app; every kzig route runs
  through the full framework (DI, middleware, contributors, return-value send).
- **std vs http.zig is not settled by this run.** Both are near what one autocannon process (4
  Node workers) on the same 12 threads can generate, so the client is part of what is measured;
  the order changes between routes in ways the work per route doesn't explain (http.zig is faster
  on the GETs and slower on the POST). A load generator that isn't the bottleneck (wrk, oha) on a
  separate machine is needed before choosing between them.
