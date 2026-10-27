#!/usr/bin/env bash
# What a user gets from the CLI: scaffold a project against this checkout,
# then build and test it after each generator (KickJS's scaffold matrix).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
zig build
KZIG="$ROOT/zig-out/bin/kzig"
WORK="$ROOT/.zig-cache/scaffold-check"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

step() { echo "== $*"; }
# sed -i differs between GNU and BSD (macOS).
edit() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }

fails() { if "$@" >/dev/null 2>&1; then echo "should have failed: $*" >&2; exit 1; fi; }

step "help is exit 0 on stdout; errors and misuse go to stderr"
for h in help --help -h; do "$KZIG" $h > out.txt 2> err.txt; grep -q "kzig new" out.txt; test ! -s err.txt; done
code=0; "$KZIG" bogus > out.txt 2> err.txt || code=$?
[ $code = 2 ] && test ! -s out.txt && grep -q "kzig new" err.txt
code=0; "$KZIG" g module task > out.txt 2> err.txt || code=$?
[ $code = 1 ] && test ! -s out.txt && grep -q "^error: no src/modules.zig" err.txt

step "kzig new refuses names Zig can't use as a package name"
fails "$KZIG" new test --kzig "$ROOT"
fails "$KZIG" new error --kzig "$ROOT"
fails "$KZIG" new a-very-long-project-name-over-the-limit --kzig "$ROOT"
test ! -e test && test ! -e error

step "kzig new demo-app"
"$KZIG" new demo-app --kzig "$ROOT"
cd demo-app
zig build test
zig build

step "kzig g module task"
"$KZIG" g module task
zig build test

step "module names that shadow template names: query, page, error"
"$KZIG" g module query
"$KZIG" g module page
"$KZIG" g module error
zig build test

step "kzig dev rebuilds and restarts on change"
set -m # its own process group, so `kill -- -$DEV` below is a terminal's Ctrl-C
PORT=39811 "$KZIG" dev > dev.log 2>&1 &
DEV=$!
set +m
waitfor() { # seconds command…
  local until=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    if [ $SECONDS -ge $until ]; then echo "timed out: $*" >&2; cat dev.log >&2; kill $DEV 2>/dev/null; exit 1; fi
    sleep 0.5
  done
}
says() { curl -sf localhost:39811/api/v1/hello | grep -q "$1"; }
waitfor 180 says "Hello World"
edit 's/Hello {s} from kzig!/Hi {s} from kzig!/' src/modules/hello/hello.service.zig
waitfor 180 says "Hi World"
edit 's/Hi {s} from kzig!/Hello {s} from kzig!/' src/modules/hello/hello.service.zig
waitfor 180 says "Hello World"
# Editor swap files aren't sources.
restarts=$(grep -c restarted dev.log)
touch src/modules/hello/.hello.service.zig.swp
sleep 2
[ "$(grep -c restarted dev.log)" = "$restarts" ] || { echo "a swap file restarted the app" >&2; cat dev.log >&2; kill $DEV; exit 1; }
rm src/modules/hello/.hello.service.zig.swp
kill -INT -- -$DEV
wait $DEV
if curl -sf localhost:39811/api/v1/hello >/dev/null 2>&1; then echo "the app outlived kzig dev" >&2; exit 1; fi
grep -q "restarted" dev.log

step "kzig g module note --minimal"
"$KZIG" g module note --minimal
zig build test

step "generated code is zig fmt clean"
zig fmt --check build.zig build.zig.zon src

step "kzig g controller/service/middleware/contributor/adapter"
"$KZIG" g controller audit --module tasks
"$KZIG" g service audit --module tasks
"$KZIG" g middleware audit
"$KZIG" g contributor current-user
"$KZIG" g adapter cache
"$KZIG" g middleware error

step "--module must name an existing module folder inside the project"
fails "$KZIG" g service evil --module ../../escape
fails "$KZIG" g service evil --module /tmp
fails "$KZIG" g service evil --module missing
test ! -e ../../escape
# Stubs aren't wired into the app; make the tests compile them.
cat > src/stubs.test.zig <<'ZIG'
const std = @import("std");
test {
    std.testing.refAllDecls(@import("modules/tasks/audit.controller.zig").AuditController);
    std.testing.refAllDecls(@import("modules/tasks/audit.service.zig").AuditService);
    std.testing.refAllDecls(@import("middleware/audit.middleware.zig"));
    std.testing.refAllDecls(@import("contributors/current-user.contributor.zig").LoadCurrentUser);
    std.testing.refAllDecls(@import("adapters/cache.adapter.zig").CacheAdapter);
    std.testing.refAllDecls(@import("middleware/error.middleware.zig"));
}
ZIG
edit 's|^    // kzig:tests|    _ = @import("stubs.test.zig");\
    // kzig:tests|' src/main.zig
zig build test

step "refuses to overwrite"
if "$KZIG" g module task 2>/dev/null; then echo "overwrote an existing module" >&2; exit 1; fi

step "a missing marker stops a module before any file is written"
cp src/modules.zig modules.zig.bak
edit '/kzig:modules/d' src/modules.zig
fails "$KZIG" g module widget
test ! -e src/modules/widgets
mv modules.zig.bak src/modules.zig

step "kzig rm module asks first"
fails "$KZIG" rm module task </dev/null
test -e src/modules/tasks

step "kzig rm module task --force"
"$KZIG" rm module task --force
test ! -e src/modules/tasks
if grep -q 'modules/tasks/' src/modules.zig src/main.zig; then echo "registry lines left behind" >&2; exit 1; fi

step "kzig rm module hello --force (a singular folder)"
"$KZIG" rm module hello --force
test ! -e src/modules/hello
edit '/stubs.test.zig/d' src/main.zig
zig build test

echo "scaffold check passed"
