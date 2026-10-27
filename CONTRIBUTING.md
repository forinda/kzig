# Contributing to kzig

Thanks for helping. Bug reports, fixes, docs and features are welcome. This guide covers setup,
the checks a change needs, and how it lands.

## Code of conduct

Be welcoming and respectful: assume good faith, take criticism of your code gracefully, and keep
discussion about the work. Harassment, insults and publishing someone's private information are
not tolerated. Report conduct problems by
[opening an issue](https://github.com/forinda/kzig/issues).

## Setup

You need **Zig 0.17.0** and Git.

```bash
git clone https://github.com/forinda/kzig.git
cd kzig
zig build test
```

## The repository

```
src/        the framework (root.zig is the public API)
examples/   task-api, the example app (ports kickjs-examples-archive behaviour)
ROADMAP.md  milestones and deliberate differences from KickJS
CLAUDE.md   detailed conventions, for people and AI agents
```

kzig ports [KickJS](https://github.com/forinda/kick-js). When a behaviour is unclear, KickJS is
the reference; a deliberate difference is listed in the roadmap.

## Making a change

1. Pick a roadmap item, or open an issue for anything not on it.
2. Make the change, with tests.
3. Run the checks:

   ```bash
   zig build test -Dhttpz
   zig fmt --check build.zig build.zig.zon src examples tests
   ```

4. Commit with a [Conventional Commits](https://www.conventionalcommits.org/) message
   (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `ci:`). Tick the roadmap item in
   the same commit.

Before 1.0, maintainers commit to `main` directly; outside contributions come as pull requests
against `main`.

## Code style

- `zig fmt` formats.
- Comments say why, not what.
- Prefer a compile error to a runtime error wherever the information exists at comptime.
- Every allocation has an owner: the app allocator or the request arena.
- Only `src/runtime/*` may touch an HTTP engine.

## Tests

- A bug fix comes with a test that fails without it.
- Tests use `std.testing.allocator`; a leak is a failure.
- Pipeline behaviour is tested through `kzig.testing`, and on every runtime once there are two.

Commit messages have no `Co-Authored-By` trailer naming an AI assistant. A pull request
description may say it was written with one.

Design notes and plans stay out of the repository (in the git-ignored `.ignored/`), and nothing
tracked refers to them.

## Issues and security

- Bugs and features: [open an issue](https://github.com/forinda/kzig/issues) with a minimal
  reproduction.
- Security vulnerabilities: report privately via
  [security advisories](https://github.com/forinda/kzig/security/advisories/new), not an issue.
