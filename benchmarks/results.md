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
