#!/usr/bin/env bash
# Release notes for a tag, from the conventional commits since the previous
# tag: Features, Fixes, Docs, then the rest. A hand-written
# .github/release-notes/<tag>.md, when there is one, goes first.
#
#   scripts/release-notes.sh v0.3.0          # previous tag found with git describe
#   scripts/release-notes.sh v0.3.0 v0.2.0   # or named
#
# Before the tag exists, the notes run to HEAD (a preview).
set -euo pipefail
cd "$(dirname "$0")/.."

tag=${1:?usage: scripts/release-notes.sh <tag> [<previous tag>]}
end=$tag
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || end=HEAD
prev=${2:-$(git describe --tags --abbrev=0 "$end^" 2>/dev/null || true)}
range=${prev:+$prev..}$end
repo=https://github.com/forinda/kzig

highlights=.github/release-notes/$tag.md
if [ -f "$highlights" ]; then cat "$highlights"; echo; fi

# One subject per line; `type: subject` or `type(scope): subject`.
subjects=$(git log --no-merges --format=%s "$range")

section() { # title, then the types it takes
  local title=$1; shift
  local lines
  lines=$(printf '%s\n' "$subjects" | grep -E "^($(IFS='|'; echo "$*"))(\([^)]*\))?!?: " | sed -E 's/^[a-z]+(\([^)]*\))?!?: /- /' || true)
  [ -z "$lines" ] && return
  printf '## %s\n\n%s\n\n' "$title" "$lines"
}

section "Features" feat
section "Fixes" fix
section "Docs" docs
# The version bump itself says nothing.
subjects=$(printf '%s\n' "$subjects" | grep -vE '^chore: version ' || true)
section "Maintenance" chore ci test refactor

if [ -n "$prev" ]; then changelog=$repo/compare/$prev...$tag; else changelog=$repo/commits/$tag; fi
cat <<NOTES
## Install

\`\`\`console
zig fetch --save git+$repo#$tag
\`\`\`

Prebuilt \`kzig\` CLIs for Linux (x86_64, aarch64) and macOS (x86_64, arm64) are attached, with \`SHA256SUMS\`.

**Full changelog**: $changelog
NOTES
