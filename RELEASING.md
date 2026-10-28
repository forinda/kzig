# Releasing kzig

A release is an annotated `v*` tag on `main`. Pushing it runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which builds the `kzig` CLI for
four targets, writes the release notes, and publishes the GitHub release. The docs site deploys
from `main` on every push, not per release.

## Versions

kzig is pre-1.0: a minor version (`0.3.0`) for new features or any breaking change, a patch
(`0.2.1`) for fixes only. The tag is `v` + the version in `build.zig.zon`.

## Steps

1. **`main` is green.** The `ci` workflow passed on the commit you'll tag, `./scripts/scaffold-check.sh`
   passes locally, and the `pages` workflow deployed.
2. **Bump the version** in `build.zig.zon` (`.version = "0.3.0"`).
3. **Write the highlights** (optional, recommended for a minor version) in
   `.github/release-notes/v0.3.0.md`: what the release is about, and anything to change when
   upgrading. Plain Markdown; it goes first in the notes.
4. **Preview the notes.** Before the tag exists, the script reads up to `HEAD`:

    ```console
    $ scripts/release-notes.sh v0.3.0
    ```

    It lists the conventional commits since the previous tag under Features (`feat:`), Fixes
    (`fix:`), Docs (`docs:`) and Maintenance (`chore:`, `ci:`, `test:`, `refactor:`), then the
    install line and the changelog link. A commit subject that reads badly here reads badly in
    the release, too.
5. **Commit and push**: `git commit -am "chore: version 0.3.0"` (the script leaves this
   commit out of the notes), then push `main`.
6. **Tag and push the tag:**

    ```console
    $ git tag -a v0.3.0 -m "kzig 0.3.0"
    $ git push origin v0.3.0
    ```

7. **Watch the `release` workflow.** It builds `kzig` for x86_64 and aarch64 Linux (musl,
   static) and x86_64 and arm64 macOS with `-Dversion=v0.3.0`, so `kzig new` scaffolds against
   this tag. It then writes `SHA256SUMS`, runs the Linux binary once, and creates the release
   with the notes. Run again on the same tag, it re-uploads the binaries and rewrites the notes.
8. **Check the release**: four `kzig-v0.3.0-<target>.tar.gz` files and `SHA256SUMS`, the notes
   as previewed, and `kzig new demo` with the downloaded CLI fetching `#v0.3.0`.

## Fixing a release

- **Notes only:** edit `.github/release-notes/<tag>.md` on `main`, then re-run the `release`
  workflow for the tag (Actions → release → Re-run), or
  `scripts/release-notes.sh <tag> | gh release edit <tag> --notes-file -`.
- **A broken build or a bad commit:** don't move the tag. Fix it on `main` and release the next
  patch version.
