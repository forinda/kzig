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

step "kzig new demo-app"
"$KZIG" new demo-app --kzig "$ROOT"
cd demo-app
zig build test
zig build

step "kzig g module task"
"$KZIG" g module task
zig build test

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
# Stubs aren't wired into the app; make the tests compile them.
cat > src/stubs.test.zig <<'ZIG'
const std = @import("std");
test {
    std.testing.refAllDecls(@import("modules/tasks/audit.controller.zig").AuditController);
    std.testing.refAllDecls(@import("modules/tasks/audit.service.zig").AuditService);
    std.testing.refAllDecls(@import("middleware/audit.middleware.zig"));
    std.testing.refAllDecls(@import("contributors/current-user.contributor.zig").LoadCurrentUser);
    std.testing.refAllDecls(@import("adapters/cache.adapter.zig").CacheAdapter);
}
ZIG
edit 's|^    // kzig:tests|    _ = @import("stubs.test.zig");\
    // kzig:tests|' src/main.zig
zig build test

step "refuses to overwrite"
if "$KZIG" g module task 2>/dev/null; then echo "overwrote an existing module" >&2; exit 1; fi

step "kzig rm module task"
"$KZIG" rm module task
test ! -e src/modules/tasks
! grep -q 'modules/tasks/' src/modules.zig src/main.zig
edit '/stubs.test.zig/d' src/main.zig
zig build test

echo "scaffold check passed"
