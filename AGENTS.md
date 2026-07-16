# Agent Instructions for Axoloty

This file is the canonical agent and contributor workflow for this repository.
For modernization context, see [ROADMAP.md](./docs/ROADMAP.md).

## Build and test

- Never run native `swift` commands on the host. Use the root Makefile, which
  runs directly inside the devcontainer and falls back to Podman or Docker:
  `make build`, `make test`, `make shell`, and `make docs`.
- By default, worktrees share a repository- and toolchain-scoped incremental
  build cache under `/tmp/coaty-swift-build/`. Every Makefile-driven SwiftPM
  operation waits for the cache lock, so concurrent worktrees must not bypass
  the Makefile. Coverage uses a separate sibling cache. Override `BUILD_DIR`,
  `COVERAGE_BUILD_DIR`, `SPM_CACHE_DIR`, or `BUILD_LOCK` for isolation or CI;
  CI uses its workspace-local `.build` directory with `BUILD_LOCK=0` and fails
  in preflight if that bypass is missing. `/tmp` is volatile and must not be
  the sole copy of generated output. Use `make worktree-bootstrap` to resolve
  dependencies and `make worktree-warm` only when an explicit prebuild is
  useful.
- Prefer adding a Makefile target to using native Swift tooling.
- Swift tests use Swift Testing only: `import Testing`, `@Test`, `#expect`,
  `#require`, and `Issue.record`. Do not add XCTest.
- Broker-backed tests must synchronize with Swift concurrency primitives or
  explicit deadlines.
- A Swift binary exported from a development container is acceptable for editor
  tooling, but Makefile targets remain the canonical build and test flow.

## GitHub-centered planning workflow

The [Axoloty Roadmap](https://github.com/users/phynics/projects/5) Project is
the live roadmap. GitHub Issues are the complete planning record.

### Agentic loop

1. **Create or refine a GitHub Issue** using the Work Plan template for
   structured tasks, or the Bug report / Feature request templates for
   lightweight tickets.
2. **Move the issue to `Ready`** on the Roadmap Project once the plan is
   approved.
3. **Implement from a dedicated worktree** named with the issue number:
   ```sh
   git worktree add .worktree/<#issue-number>-<slug> -b <#issue-number>-<slug> main
   ```
4. **Open a pull request** targeting `main` with `Closes #<issue-number>` in
   the description.
5. **Move the issue through `In progress` → `In review`** on the Project as
   the PR advances.
6. **Merge the PR**; the issue closes automatically via the `Closes` keyword.
7. **Move the issue to `Done`** and remove the worktree.

### Historical tickets

Historical T-### tickets are migrated to GitHub Issues with their T-ID retained
in the title and body. See the migration ledger in `.github/MIGRATION_LEDGER.md`
for the mapping.

All new work uses GitHub issue numbers. The `docs/superpowers/specs/` and
`docs/superpowers/plans/` directories are retired as active workflow locations;
their history is retained in Git.

## Code conventions

### Source files

- New comment-capable source files need this header, using the first
  publication year and never changing it later:

  ```swift
  // Copyright (c) <year> <contributor>. Licensed under the MIT License.
  ```

- Follow the repository SwiftLint configuration.
- Every public type, property, method, initializer, and protocol needs a
  DocC comment. Document parameters, returns, and errors when applicable; use
  double-backtick symbol links; update public API documentation with the API.

### Errors

- Use ErrorKit for package errors. Package-defined errors conform to
  `Throwable` and provide a stable `userFriendlyMessage`; prefer
  `AxolotyError` unless a distinct public boundary needs another type.
- Do not expose bare `Error`, encoding/decoding, or dependency errors from an
  Axoloty API. Convert them to an Axoloty `Throwable` with actionable context.
- Failure tests assert the error category and `userFriendlyMessage`. Preserve
  public signatures unless an approved plan authorizes a breaking change.

### Commits

- Use Conventional Commits.
- Commit with this checkout's configured identity. Never add bot co-author
  trailers.
