#!/usr/bin/env bash
# Benchmarks kzig (std and http.zig runtimes) against KickJS on Express.
# Needs a kick-js checkout (for autocannon, express, zod) and a
# kickjs-examples-archive checkout with minimal-api built, next to this repo
# or at KICKJS_DIR / ARCHIVE_DIR. Writes benchmarks/results.md.
set -euo pipefail
cd "$(dirname "$0")/.."

KICKJS=$(realpath "${KICKJS_DIR:-../kick-js}")
ARCHIVE=$(realpath "${ARCHIVE_DIR:-../kickjs-examples-archive}")
DURATION=${DURATION:-10}
CONNECTIONS=${CONNECTIONS:-100}
PORT=4567
AUTOCANNON="$KICKJS/node_modules/.bin/autocannon"
BODY='{"name":"Ada","email":"ada@example.com","age":36}'

zig build bench -Dhttpz -Doptimize=ReleaseFast

SERVER_PID=
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

wait_up() {
  for _ in $(seq 1 100); do
    curl -s -o /dev/null "localhost:$PORT$1" && return 0
    sleep 0.1
  done
  echo "server did not start" >&2
  return 1
}

measure() { # name path [autocannon args]
  local name=$1 path=$2
  shift 2
  "$AUTOCANNON" -c "$CONNECTIONS" -d 2 -w 4 "$@" "http://localhost:$PORT$path" >/dev/null 2>&1 # warm-up
  "$AUTOCANNON" -c "$CONNECTIONS" -d "$DURATION" -w 4 -j "$@" "http://localhost:$PORT$path" 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);
      console.log(`| ${process.argv[1]} | ${process.argv[2]} | ${Math.round(r.requests.average).toLocaleString("en")} | ${r.latency.average} | ${r.latency.p99} | ${r.non2xx} | ${r.errors + r.timeouts} |`)})' \
      "$name" "$path"
}

suite() { # name command...
  local name=$1
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  SERVER_PID=$pid
  wait_up "$PROBE"
  for route in "${ROUTES[@]}"; do
    if [ "$route" = /api/v1/validate ]; then
      measure "$name" "$route" -m POST -H content-type=application/json -b "$BODY"
    else
      measure "$name" "$route"
    fi
  done
  kill -INT "$pid"
  wait "$pid" 2>/dev/null || true
  SERVER_PID=
}

{
  echo "| server | route | req/s | avg ms | p99 ms | non-2xx | errors |"
  echo "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
  ROUTES=(/api/v1/hello /api/v1/json /api/v1/echo/42 /api/v1/validate)
  PROBE=/api/v1/json
  suite "kzig std" env PORT=$PORT ./zig-out/bin/bench-std
  suite "kzig http.zig" env PORT=$PORT ./zig-out/bin/bench-httpz
  ROUTES=(/api/v1/hello)
  PROBE=/api/v1/hello
  suite "KickJS minimal-api (Express)" env PORT=$PORT NODE_ENV=production node "$ARCHIVE/minimal-api/dist/index.js"
  ROUTES=(/api/v1/json /api/v1/echo/42 /api/v1/validate)
  PROBE=/api/v1/json
  suite "Express (KickJS benchmark app)" env PORT=$PORT NODE_PATH="$KICKJS/node_modules" node benchmarks/express-baseline.cjs
} | tee benchmarks/results.md
