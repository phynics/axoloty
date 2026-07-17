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

1. **Fetch and check `origin/main` before branching.** This file and the
   workflow it describes can change between sessions (it was rewritten
   mid-session once already — planning moved from `docs/superpowers/` to
   GitHub Issues and the default branch was renamed `master` → `main`). Do
   not assume a locally cached `AGENTS.md`, branch name, or directory layout
   is current; `git fetch origin main` and diff against it first.
2. **Search existing issues before filing** (`gh issue list`, `gh issue
   view`). This repo's backlog is populated with `T-NNN — <title>` issues
   migrated from the old ticket system; a title-only search can miss one,
   so also grep issue bodies for the topic. Filing a duplicate wastes a
   round trip closing it.
3. **Create or refine a GitHub Issue** using the Work Plan template for
   structured tasks, or the Bug report / Feature request templates for
   lightweight tickets.
4. **Move the issue to `Ready`** on the Roadmap Project once the plan is
   approved.
5. **Implement from a dedicated worktree** named with the issue number:
   ```sh
   git worktree add .worktree/<#issue-number>-<slug> -b <#issue-number>-<slug> main
   ```
6. **Open a pull request** targeting `main` with `Closes #<issue-number>` in
   the description.
7. **Move the issue through `In progress` → `In review`** on the Project as
   the PR advances.
8. **Merge the PR**; the issue closes automatically via the `Closes` keyword.
9. **Move the issue to `Done`** and remove the worktree.

### Historical tickets

Historical T-### tickets are migrated to GitHub Issues with their T-ID retained
in the title and body. See the migration ledger in `.github/MIGRATION_LEDGER.md`
for the mapping.

All new work uses GitHub issue numbers. The retired `docs/superpowers/`
spec/plan directory has been removed from the tree; its history is retained
in Git.

### Session hygiene

- **Verify `pwd` and `git branch --show-current` immediately before every
  commit or push**, not just when something looks off. A shell's working
  directory can silently reset to the main checkout between tool
  invocations (e.g. after a `cd` into `/tmp` for a throwaway check); a
  commit made there lands on whatever branch that checkout has, not the
  worktree branch you meant. Cheap to check every time, expensive to
  discover after the fact.
- **One fix per PR, each rooted in a local repro.** When chasing a
  multi-layer failure (e.g. a broken CI pipeline where fixing one bug
  reveals the next), reproduce and verify each bug locally before writing
  the fix, and land each as its own commit/PR with a message explaining
  what earlier fix exposed it. Bundling multiple unrelated root causes into
  one change makes it hard to tell which fix actually mattered if CI is
  still red afterward.
- **Filing a new issue proactively (not asked for) is scope creep**, even
  when it's clearly correct and blocks the task at hand — surface the
  finding to the requester and let them decide, unless they've already
  granted standing authorization to act on discoveries. Once they say to
  proceed, treat that as authorization for that one issue, not a standing
  policy for future sessions.

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

### Wire compatibility

Axoloty targets wire compatibility with the pinned CoatyJS reference agent
(`Tests/WireCompatibility/ReferenceAgents/`). The reference is the source of
truth for wire shape.

- **Match CoatyJS where possible.** When Axoloty and CoatyJS disagree on a
  wire detail (field presence, payload wrapping, encoding overload), the
  default is to change Axoloty to match the reference, not to record the
  difference as accepted. A captured discrepancy is a defect to fix, not a
  divergence to ratify — unless matching is impossible or more harmful than
  breaking.
- **Remain compatible despite divergence.** When a divergence is unavoidable,
  Axoloty must still tolerate the peer's wire shape: decode optional fields
  defensively (never force-unwrap a field a peer may omit), accept the bare
  payload an external producer sends, and so on. Trapping on a peer's
  legitimate omission is a bug, not a compatibility boundary.
- **No accidental divergences.** A wire-format or field-presence change
  requires a regression test locking in the new behavior and an update to
  `Tests/WireCompatibility/CompatibilityMatrix.md`. Record only deliberate,
  unavoidable divergences (e.g. a platform constraint like CoatyJS hardcoding
  QoS 0) with capture evidence and a linked decision.
