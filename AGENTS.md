# Agent Instructions for Axoloty

This document is the canonical set of instructions for any agent (or human)
working in this repository. `CLAUDE.md` just points here — keep this file as
the single source of truth so the two never drift apart.

For the overall modernization plan and current phase, see
[ROADMAP.md](./docs/ROADMAP.md).

## Building & testing: podman only, never native `swift`

This repository is developed on NixOS, where the native Swift toolchain
cannot run correctly (dynamic-linking failures). Because of that:

- **Never invoke `swift build`, `swift test`, `swift package`, etc. directly
  on the host.** They will not work reliably on this machine, and CI does
  not run them natively either.
- Always use the root `Makefile`, which wraps everything through `podman`:
  - `make build` — build the package inside the container.
  - `make test` — run the test suite inside the container.
  - `make shell` — drop into an interactive shell inside the container, for
    anything not already covered by a Makefile target.
  - `make docs` — generate API documentation via DocC into `.build/docc`.
- The container image and its definition live under `.devcontainer/`
  (`Dockerfile`, `devcontainer.json`). CI (`.github/workflows/ci.yml`) runs
  the same containerized flow, so a green `make build && make test` locally
  should predict a green CI run.

Swift tests use the toolchain-provided Swift Testing framework exclusively.
Test files import `Testing`, declare cases with `@Test`, assert with `#expect`
and `#require`, and record non-fatal issues with `Issue.record`. Do not add
XCTest imports, `XCTestCase` subclasses, XCTest expectations, or XCTest
assertions. Broker-backed tests should use Swift concurrency primitives or
explicit deadlines for synchronization. The Swift 6 toolchain in
`.devcontainer/Dockerfile` is therefore the minimum supported test toolchain;
the package manifest may retain its existing tools-version floor where the
toolchain can provide the Testing module without changing production language
mode.

If a Makefile target doesn't exist yet for something you need, prefer adding
one over reaching for the native toolchain.

An alternative for *interactive* tooling (editor LSP, `swift repl`):
exporting the `swift` binary from a Swift dev container via
[distrobox](https://github.com/89luca89/distrobox). That's fine for
editing-time ergonomics, but the podman/Makefile flow above remains the
canonical build/test path — it's what CI reproduces.

## Workflow: specs → tickets → worktrees

Work is planned and executed through a local, gitignored spec/ticket
pipeline, not through ad-hoc branches off a shared checkout:

- `.claude/specs/` — markdown specs describing a piece of work at a
  conceptual level. Local-only, gitignored, not part of the shipped repo
  history.
- `.claude/tickets/` — markdown tickets derived from specs, scoped to a
  single unit of work. Also local-only and gitignored.
- **One git worktree per ticket.** For a ticket, create an isolated worktree
  under the repository-local `.worktree/` directory and branch off `master`:

  ```sh
  git worktree add .worktree/<ticket-id> -b <ticket-id>-<slug> master
  ```

  Do all work for that ticket inside its own worktree so parallel efforts
  (including other agents') never collide on the same working tree.
- Open a pull request from the ticket's branch back to `master`.
- Once the PR is merged, remove the worktree (`git worktree remove
  .worktree/<ticket-id>`) — don't leave stale worktrees lying around.

This lets multiple agents (or an agent and a human) work on independent
tickets concurrently without stepping on each other's files.

## Coding conventions

### License header

Attach a license and copyright notice to the top of every new source file:

```swift
// Copyright (c) <year> <contributor>. Licensed under the MIT License.
```

`<year>` is the year of *first* publication and must **not** be changed when
the file is modified later. Don't add additional copyright notices or dates
on revision. This applies to any source file that can hold a comment easily
(e.g. `.swift`) and that contributes original content to the project (not
plain configuration files). Contributions without this header on new source
files won't be accepted.

### Commit style

Use [Conventional Commits](https://conventionalcommits.org/) for commit
messages:

```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

This keeps history structured enough to eventually support automatic
changelog generation and version bumping, even though the current build
process doesn't yet automate that.

### Coding style

The framework includes a custom [SwiftLint](https://github.com/realm/SwiftLint)
configuration (`.swiftlint.yml`) that also applies to Coaty application
projects consuming this package.

### Documentation comments

DocC-style documentation comments are the single source of API documentation:
the DocC catalog produced by `make docs` is generated from in-source comments,
not from a hand-maintained reference. Every public type, property, method,
initializer, and protocol declaration must carry a [DocC](https://www.swift.org/documentation/docc/)
documentation comment (`///` for single-line, `/** … */` for multi-line)
written in DocC markup.

- Document parameters, return values, and thrown errors with the
  `- Parameter:`, `- Returns:`, and `- Throws:` callouts.
- Cross-reference other symbols with double-backtick links (`` ``Symbol`` ``)
  so the catalog resolves them automatically.
- Keep the documentation co-located with the declaration it describes; do not
  duplicate API-reference content in standalone `.md` articles — those are
  reserved for guides and conceptual overviews.
- When modifying a public API, update its documentation comment in the same
  change so the catalog never drifts from the code.

### Error handling

Use [ErrorKit](https://github.com/FlineDev/ErrorKit) for all errors handled by
the package. Package-defined errors must conform to `Throwable` and provide a
stable, user-facing `userFriendlyMessage`; use `AxolotyError` unless a
distinct public error type is necessary for a clear API boundary.

Do not allow bare `Error`, `DecodingError`, `EncodingError`, or dependency
errors to escape an Axoloty API. Convert them at the package boundary to a
`Throwable` Axoloty error while preserving actionable diagnostic context in
the message. At presentation and logging boundaries, obtain user-facing text
through ErrorKit rather than duplicating ad-hoc error formatting.

Tests that exercise failing paths must assert both the error category and its
`userFriendlyMessage`. New or changed error behavior must maintain existing
public signatures unless the associated ticket explicitly authorizes a
source-breaking migration.

### Git identity

Commits in this repository must be made using the actual configured git
identity for this checkout (`user.name` / `user.email` — currently Atakan
DULKER / contact@atkn.me). **Never** add a `Co-Authored-By: Claude` or any
other bot co-author trailer to a commit in this repository.

## More detail

This file is the single source of truth for build/test/docs commands, the
specs/tickets/worktree workflow, and coding conventions — there is currently
no separate contributor-facing document (this fork isn't taking external
contributions right now). `README.md` gives a project overview and points
here and to `docs/ROADMAP.md`; `docs/ROADMAP.md` covers the multi-phase modernization
plan this work is part of.
