# Agent instructions for Axoloty

This file is the stable contributor constitution and repository index. [`ARCHITECTURE.md`](./ARCHITECTURE.md) records accepted boundaries, [`CONTEXT.md`](./CONTEXT.md) defines canonical language, [`docs/ROADMAP.md`](./docs/ROADMAP.md) summarizes active strategy, and GitHub Issues are the complete planning record.

Scoped instructions add local constraints:

- [`Packages/AxolotyWire/AGENTS.md`](./Packages/AxolotyWire/AGENTS.md) — portable wire boundary;
- [`Embedded/AGENTS.md`](./Embedded/AGENTS.md) — Embedded Swift and hardware policy;
- [`Tools/AGENTS.md`](./Tools/AGENTS.md) — orchestration and first-party tools;
- [`Tests/AGENTS.md`](./Tests/AGENTS.md) — test tiers and compatibility evidence.

## Documentation authority

1. Executable code, manifests, and tests describe actual current behavior.
2. Accepted ADRs record hard-to-reverse decisions and rationale.
3. GitHub issues and projects hold plans and unresolved decisions.
4. ROADMAP summarizes active strategy.
5. README, API, support, migration, and release documents state public contracts.
6. AGENTS files define contributor policy.

Disagreement is a defect. `ARCHITECTURE.md` separates the implemented current state from the accepted migration delta; it is not a planning scratchpad. Historical release notes are immutable. Supersede ADRs rather than rewriting accepted history. Git history is the archive; delete obsolete mixed plan/current-state prose once durable rationale is captured.

Temporary architecture violations require a narrow, expiring entry in [`docs/architecture-exceptions.yml`](./docs/architecture-exceptions.yml). An exception cannot redefine an invariant.

## Normal workflow

Use the repository entry points rather than reproducing container or toolchain commands:

1. `make verify` — ordinary pre-PR verification.
2. `make test-one FILTER='SuiteOrTest'` — one bounded test process.
3. `make test-tier TIER=unit` — one canonical tier.
4. `make explain TIER=unit` — inspect the graph and policies without execution.

Use `make verify-ci` only to reproduce required CI. Release and hardware validation are opt-in and must never be folded into ordinary verification. `Tests/TESTING.md` owns the executable tier contract.

The Makefile is a thin compatibility/bootstrap surface; orchestration policy belongs in `AxolotyTooling`. Linux product and Embedded Swift builds use the pinned container through root Make targets. Do not run native Swift product builds on Linux. `Package.resolved` is authoritative; dependency resolution changes require the dedicated repository target.

## GitHub-centered planning

- Fetch `origin/main` and compare it before branching.
- Search issue titles and bodies before filing; preserve historical T-IDs.
- Keep designs, specifications, implementation plans, checklists, and planning updates in GitHub issues or comments. Do not commit local ticket/specification files.
- Implement each authorized issue in a dedicated worktree and branch.
- Keep one fix per PR, rooted in a local reproduction where applicable.
- Update the owning issue when scope, decisions, sequencing, or acceptance criteria change.
- Open PRs against `main` with `Closes #<issue-number>`.
- Creating an unrequested issue is scope expansion; surface it to the requester first.

Before every commit or push, verify the working directory and current branch. Preserve unrelated user changes and stage only the intended paths. Use Conventional Commits with the checkout's configured identity and no bot co-author trailer.

## Architectural invariants

- Host and static runtime profiles share the production wire and protocol critical path.
- `coaty/3` remains sealed as Coaty Core Profile 3; new primitives use separately versioned profiles.
- Portable protocol state is finite and saturation is structured and atomic.
- Borrowed wire values never cross asynchronous or isolation boundaries.
- Static runtime code contains no protocol rule absent from `AxolotyProtocol`.
- General raw MQTT application APIs are not part of the target runtime.
- Ordinary verification never probes, reserves, flashes, or requests privileges for hardware.

See [`docs/adr/`](./docs/adr/) for rationale and [`docs/protocol/coaty-core-3.md`](./docs/protocol/coaty-core-3.md) for protocol authority.

## Source conventions

- New comment-capable source files need `// Copyright (c) <year> <contributor>. Licensed under the MIT License.` using the first publication year.
- Follow the repository SwiftLint configuration.
- Public types, properties, methods, initializers, and protocols require DocC, including parameters, return values, and errors where applicable.
- Swift tests use Swift Testing, never XCTest.

### Errors during the transition

Current host package APIs use `AxolotyError`/ErrorKit and must not leak bare foreign errors. Wrap foreign errors at the public boundary and log the full error chain only where a failure is handled, dropped, converted, or terminates an operation. Portable protocol layers use focused typed errors and must not depend on ErrorKit.

### Logging

Use `LogManager.logger(.subsystem)` for existing host concerns. Keep message text stable and put dynamic values in metadata. Correlate multi-hop flows with an existing correlation or attempt identifier, or mint a local one without changing the wire contract.

### Wire compatibility

The pinned CoatyJS reference agent is the source of truth for Coaty wire shape. Match it where possible and tolerate legitimate peer omissions. A wire change requires regression coverage and an update to `Tests/WireCompatibility/CompatibilityMatrix.md`; record only deliberate, unavoidable divergences with capture evidence and a linked decision.
