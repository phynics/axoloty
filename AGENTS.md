# Agent instructions for Axoloty

This is the repository-wide contributor constitution and the sole `AGENTS.md`.
Keep policy here; add a nested guide only for a durable constraint that cannot
be stated clearly at this level.

## Documentation authority

1. Executable code, manifests, and tests describe current behavior.
2. Accepted ADRs record hard-to-reverse decisions and rationale.
3. GitHub issues and projects hold plans and unresolved decisions.
4. `docs/ROADMAP.md` summarizes active strategy.
5. README, API, support, migration, and release documents state public contracts.
6. This file defines contributor policy.

Treat disagreement as a defect. `ARCHITECTURE.md` separates implemented state from accepted migration work. Do not use it as a planning scratchpad. Historical release notes are immutable. Supersede an accepted ADR instead of rewriting it. Delete obsolete planning prose after durable rationale is recorded.

Record a temporary architecture violation as a narrow, expiring entry in `docs/architecture-exceptions.yml`. An exception cannot redefine an invariant.

## Supported workflow

Use repository entry points:

1. `make verify` — ordinary pre-PR verification.
2. `make test-one FILTER='SuiteOrTest'` — one bounded test process.
3. `make test-tier TIER=ci` — one canonical hardware-free tier.
4. `make explain TIER=ci` — inspect the graph and policies without execution.

Use `make verify-ci` only to reproduce the required CI plan. Use `make checkpoint` and `make checkpoint-hardware` for release validation. Ordinary verification never probes hardware.

The supported external-consumer boundary is `docs/embedded-consumer-contract.json`, reached through `axoloty-tool embedded consumer prepare`. A consumer selects a checkout with `AXOLOTY_SOURCE_DIR` and owns its own scratch space. Never expose Axoloty's root `.build`, a parent-directory layout, or anything under `Tests/` to a firmware consumer, and never copy portable source out of this repository.

Linux product and Embedded Swift builds use the pinned container through root Make targets. Do not run native Swift product builds on Linux. Run `make embedded-toolchain-doctor` for device-independent setup diagnostics. A cold mounted-worktree build on a four-core Linux host can spend about 15 minutes compiling tooling before the requested node starts. The external consumer proof may run for up to two hours; compiler and heartbeat output are progress even when no test name changes, so let the repository timeout own the deadline and do not cancel an advancing build. Keep one `AXOLOTY_PROOF_RUN_ID` across proof build, flash, and validation.

The Makefile and shell launchers are thin bootstrap and compatibility layers. Put orchestration policy, validation, and lifecycle behavior in `AxolotyTooling`. `Package.resolved` is authoritative. Use the repository resolution target for an authorized dependency update.

## GitHub-centered work

- Fetch and compare `origin/main` before branching.
- Search issue titles and bodies before filing. Preserve historical T-IDs.
- Keep designs, plans, checklists, and planning updates in GitHub issues or comments.
- Implement each authorized issue in its own worktree and branch.
- Keep one fix per PR and begin bug fixes with a local reproduction.
- Update the owning issue when scope, sequencing, decisions, or acceptance criteria change.
- Open PRs against `main` with `Closes #<issue-number>`.
- Ask before creating an issue that the user did not request.

Before each commit or push, verify the worktree and branch. Preserve unrelated changes and stage only intended paths. Use Conventional Commits with the configured identity and no bot co-author trailer.

## Architectural invariants

- Host and static runtime profiles share the production wire and protocol path.
- `coaty/3` remains sealed as Coaty Core Profile 3. Add new behavior through a separately versioned profile.
- Portable state is finite. Saturation and stale-token rejection are structured and atomic.
- Borrowed values stay inside synchronous calls. Materialize owned values before an asynchronous or isolation boundary.
- Static runtime and transport adapters contain no protocol rule absent from `AxolotyProtocol`.
- The runtime does not expose a general raw-MQTT application API.
- Ordinary verification never probes, reserves, flashes, or requests hardware privileges.

See `ARCHITECTURE.md`, `CONTEXT.md`, `docs/adr/`, `docs/ROADMAP.md`, and `docs/protocol/coaty-core-3.md` for the enforced design and vocabulary.

## Module ownership

- `AxolotyWire` owns profile-neutral wire syntax, route envelopes, codecs, validation, low-level object-envelope decoding, wire values, parser workspaces, and wire errors. It owns no protocol state, runtime, transport, Foundation, ErrorKit, logging, MQTT, or NIO policy.
- `AxolotyObjectModel` owns bounded semantic objects, schemas, presence, number and JSON views, predicates, and caller-owned schema registration. Preserve unknown fields and numeric lexemes. Use literal-inline storage and atomic mutations. Registration is fixed-inline, explicit, runtime-local, and caller-sealed; identical repeats are idempotent, while conflicts and saturation fail atomically. Do not add reflection, global registration, growable collection storage, or escaping captured closures.
- `AxolotyObjectMacros` contains only SwiftSyntax macro implementation and diagnostics. Pin its SwiftSyntax toolchain version. Generated schemas must match manual `ObjectSchema` behavior and must not hide runtime registration or unbounded storage. Diagnose invalid schemas during expansion. Never check in generated Swift as a substitute for the source contract.
- `AxolotyCoatyModels` contains complete first-party portable schemas. Do not publish marker types for models without a bounded representation. Preserve Coaty wire names and defaults, validate semantics, and fail atomically on overflow.
- `AxolotyProtocol` owns the sealed profile inventory, routing keys, frame boundaries, typed protocol errors, bounded state, action sinks, filter adapter, and shared processor. It performs no allocation, asynchronous work, transport, lifecycle, actor, or logging work. Callers supply time and bounded sinks. Subscriptions use generation-protected slot tokens; handlers use noncapturing numeric-context entries. Reject saturation and stale tokens without partial mutation.
- `AxolotyStaticRuntime` owns fixed synchronous composition around one shared processor, one subscription registry, one caller-drained owning action sink, and one slot-indexed endpoint registry. It may keep one pending latest value, but no transport policy, actor, task, logging, controller, or second family switch. Its `tiny = 1`, `esp32C6Static = 16`, and `hostDefault = 64` aliases describe storage capacity, not scheduling.
- `Source/Runtime` owns host lifecycle, scheduling, transport ownership, bounded ingress, supervised handlers, and diagnostics. `RuntimeBuilder` is mutable only before `finish()`; `RuntimeDefinition` is immutable; `AxolotyRuntime` is single-use and actor-isolated. Copy transport data before admission, fail rather than drop a full protocol ingress queue, and keep handler values owned and sendable. Do not expose raw routes or wildcard subscriptions, add a second processor, or create an unbounded task per message.
- `AxolotySensorThings` owns typed source and direct-observation workflows. Use one bounded runtime-owned coordinator and the existing Coaty operation families. Do not create a transport, processor, detached task hierarchy, raw MQTT route, or retired controller API.
- `Embedded` owns platform and transport integration, identity persistence, clocks, Wi-Fi, hardware IO, storage, and firmware composition. Firmware deploys the static runtime and must not reimplement protocol semantics. This ownership is migrating to `phynics/axoloty-embedded` under [epic #845](https://github.com/phynics/axoloty/issues/845); until [#848](https://github.com/phynics/axoloty/issues/848) lands, firmware stays here and changes to it remain behavior-preserving. Never commit Wi-Fi or broker credentials. Keep device paths, credentials, reachability, and live timing in operator configuration.
- `Tools` contains first-party developer tools. Inspector and MCP use supported runtime interfaces and no privileged protocol backdoor. If a tool needs arbitrary MQTT packets, give the tool its own transport client. Keep machine-readable stdout free of dynamic diagnostics.
- `Tests` and `Tests/Support/test-tiers.json` own verification policy and evidence. Use Swift Testing, explicit concurrency or deadlines for broker tests, and root Make targets. Keep offline fixtures distinct from fresh live-wire evidence. Replay identical overlapping traces through host and static profiles and compare state, actions, and structured rejections.

Portable packages compile the same production sources for host and Embedded Swift. Conditional compilation may adapt unavailable mechanics but must not change semantics. Keep portable packages free of Foundation, MQTT and NIO, ErrorKit, logging, actors, controllers, lifecycle frameworks, transports, process-global state, and runtime tasks unless the ownership list above explicitly allows them.

## Source conventions

- Add `// Copyright (c) <year> <contributor>. Licensed under the MIT License.` to new comment-capable source files, using the first publication year.
- Follow the repository SwiftLint configuration.
- Add DocC to public types, properties, methods, initializers, and protocols. Document parameters, returns, and errors when present.
- Write Swift tests with Swift Testing, never XCTest.

Host package APIs wrap foreign errors as `AxolotyError` at the public boundary. Portable protocol layers use focused typed errors and do not depend on ErrorKit. Log the full error chain only where a failure is handled, dropped, converted, or terminates an operation.

Applications choose `swift-log` bootstrap and filtering. Use `Logging.Logger` only in targets that declare `swift-log`. Keep message text stable and dynamic values in metadata. Reuse or mint a local correlation or attempt identifier for multi-hop work without changing the wire contract. Use `RuntimeDiagnostics` for bounded host counters and streams.

## Wire compatibility

The pinned CoatyJS reference agent under `Tests/Support/WireCompatibility/ReferenceAgents/` is the wire-shape authority.

- Change Axoloty to match CoatyJS when possible. Treat a captured discrepancy as a defect unless matching is impossible or causes greater breakage.
- Tolerate a legitimate peer shape when divergence is unavoidable. Decode optional fields defensively and accept bare payloads emitted by external producers.
- Add a regression test and update `docs/wire-compatibility.md` for every wire-format or field-presence change. Record only deliberate, unavoidable divergence with capture evidence and a linked decision.
