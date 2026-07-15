# Agent Instructions for Axoloty

This file is the canonical agent and contributor workflow for this repository.
For modernization context, see [ROADMAP.md](./docs/ROADMAP.md).

## Build and test

- Never run native `swift` commands on the host. Use the root Makefile, which
  runs through podman: `make build`, `make test`, `make shell`, and `make docs`.
- Prefer adding a Makefile target to using native Swift tooling.
- Swift tests use Swift Testing only: `import Testing`, `@Test`, `#expect`,
  `#require`, and `Issue.record`. Do not add XCTest.
- Broker-backed tests must synchronize with Swift concurrency primitives or
  explicit deadlines.
- A Swift binary exported from a development container is acceptable for editor
  tooling, but Makefile targets remain the canonical build and test flow.

## Planning and worktrees

- Keep canonical design specs in `docs/superpowers/specs/` and implementation
  plans in `docs/superpowers/plans/`. Keep agent-local scratch work in the
  ignored `.agents/` directory.
- Use one worktree per plan. Create every worktree under the repository-local,
  ignored `.worktree/` directory, branching from `master`:

  ```sh
  git worktree add .worktree/<plan-id> -b <plan-id>-<slug> master
  ```

- Do all plan work in its worktree. Delegated agents work and commit only in
  their own worktrees; review and merge their branches before integration.
- Open a pull request to `master`, then remove its merged worktree with
  `git worktree remove .worktree/<plan-id>`.

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
