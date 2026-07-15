# Modernization Roadmap Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining Phase 2–7 roadmap outcomes with independently reviewable, container-verified tickets.

**Architecture:** Documentation and test-layout work are independent early slices. The concurrency migration establishes one AsyncSequence observation boundary, migrates producers and consumers in bounded layers, and removes RxSwift only after all call sites move. Existing wire-compatibility tickets remain the protocol gate; WASM is an evidence-producing spike after dependency removal.

**Tech Stack:** Swift 6.3 container toolchain, SwiftPM, Swift Testing, Swift concurrency, ErrorKit, DocC, mqtt-nio, swift-log, Podman, Mosquitto, SwiftWasm/WASI.

**Specs:** `.agents/plans/0002-wire-compatibility-testing.md`, `.agents/plans/0003-docc-documentation.md`, `.agents/plans/0004-concurrency-and-errors.md`, `.agents/plans/0005-test-organization.md`, `.agents/plans/0006-wasm-feasibility.md`, `.agents/plans/0007-package-rename.md`.

## Global Constraints

- Never invoke host-native `swift`; use Makefile targets backed by Podman.
- Each ticket uses a dedicated worktree and branch from `master` as required by `AGENTS.md`.
- Tests use `Testing`, `@Test`, `#expect`, and `#require`; XCTest is forbidden.
- Preserve MQTT topic, payload, QoS, retain, ordering, and lifecycle behavior unless an approved compatibility decision says otherwise.
- Coordinate public names with T-023; complete or explicitly defer that rename before creating new public API and documentation names.
- New Swift source files carry the repository MIT copyright header.
- Use Conventional Commits and the configured human git identity without bot co-author trailers.

---

### Task 1: Resolve naming baseline (existing T-023)

**Files:** `Package.swift`, `Source/**`, `Tests/**`, `README.md`, `docs/ROADMAP.md`.

**Interfaces:** Produces the canonical package, product, module, test-target, logger, and error-type names consumed by every later ticket.

- [ ] Reconcile the partially renamed manifest with T-023 acceptance criteria and record the final public names.
- [ ] Run `make build` and `make test`; expect both commands to exit 0.
- [ ] Merge T-023 before documentation or new public concurrency APIs are named.

### Task 2: Build DocC documentation (T-024)

**Files:** Create `Source/CoatySwift.docc/CoatySwift.md` and `Source/CoatySwift.docc/GettingStarted.md` (replace `CoatySwift` with the T-023 canonical target name); modify `Makefile`, `README.md`, and `docs/ROADMAP.md`.

**Interfaces:** Consumes the canonical module name from T-023. Produces `make docs` and the package documentation archive.

- [ ] Add a catalog landing page linking ``GettingStarted`` and the module's principal runtime types.
- [ ] Add a getting-started article containing the exact SPM dependency/product declaration and a compiling minimal configuration/startup example.
- [ ] Add a containerized `docs` target using `swift package generate-documentation --target <canonical-target> --transform-for-static-hosting --output-path .build/docc` and make DocC diagnostics fail the command.
- [ ] Run `make docs`; expect exit 0 and `.build/docc/index.html`.
- [ ] Run `make build`; expect exit 0, then commit `docs: add DocC catalog and build target`.

### Task 3: Adopt ErrorKit policy (T-025)

**Files:** Modify `Package.swift`, the canonical error source under `Source/Common/`, relevant error tests, `README.md` or a DocC migration article, and `docs/ROADMAP.md`.

**Interfaces:** Produces a direct `ErrorKit` target dependency and a written rule for `Throwable`/`Catching`; later concurrency tickets consume that rule for new errors.

- [ ] Add a test proving the chosen treatment of the existing package error preserves its public cases and descriptions.
- [ ] Run the focused test through a new or existing Make target; expect it to fail before ErrorKit integration for the intended conformance/policy assertion.
- [ ] Pin ErrorKit, implement only the accepted conformance or adapter, and document the migrate/wrap/retain decision.
- [ ] Run `make build && make test-fast`; expect exit 0, then commit `feat: adopt ErrorKit error policy`.

### Task 4: Establish async observation core (T-026)

**Files:** Modify `Source/Communication/Manager/CommunicationManager.swift`, `CM+Observe.swift`, `CM+Util.swift`, `Source/Communication/Client/CommunicationClient.swift`; create focused communication tests under the post-T-029 path if T-029 has merged.

**Interfaces:** Produces typed or event-filtered `AsyncStream`/`AsyncThrowingStream` factories with explicit buffering, cancellation, and termination semantics. T-027 and T-028 consume these APIs.

- [ ] Write Swift Testing cases for filtering, ordered delivery, cancellation cleanup, completion/error propagation, and bounded-buffer behavior.
- [ ] Run the focused communication test with a Make target; expect the new tests to fail because the async API is absent.
- [ ] Implement the minimal continuation registry behind an actor or Sendable-safe isolation boundary and bridge incoming client events once.
- [ ] Run focused tests and `make test-wire`; expect exit 0, then commit `feat(communication): add async event observation`.

### Task 5: Migrate communication APIs (T-027)

**Files:** Modify `Source/Communication/Manager/CM+Observe.swift`, `CM+Publish.swift`, `CommunicationManager.swift`, and communication tests.

**Interfaces:** Consumes T-026 streams. Produces Rx-free public communication observation and request/reply APIs used by controllers.

- [ ] Add tests for each event family—Advertise/Deadvertise, Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return, Channel, Associate, IoState, and IoValue—including timeout and cancellation behavior.
- [ ] Migrate one event family at a time, running its focused tests after each change.
- [ ] Add deprecated non-Rx compatibility shims only where they can exist without retaining RxSwift; document source-breaking removals.
- [ ] Run `make test-fast && make test-wire-live`; expect exit 0, then commit `refactor(communication): migrate events to async sequences`.

### Task 6: Migrate controller and runtime consumers (T-028)

**Files:** Modify `Source/Runtime/Controller.swift`, `Container.swift`, `Source/Controller/ObjectLifecycleController.swift`, `Source/IORouting/**`, `Source/SensorThings/*Controller*.swift`, MQTT integration files, their tests, and `Package.swift`.

**Interfaces:** Consumes T-027 communication APIs. Produces actor/task-based lifecycle management and a package with no RxSwift dependency.

- [ ] Add tests that cancellation stops controller tasks, container shutdown awaits them, and repeated start/stop does not leak subscriptions.
- [ ] Replace subscriptions/disposal bags subsystem by subsystem with owned `Task` values and structured cancellation.
- [x] Search with `rg -n RxSwift Source Tests Package.swift`; no matches remain after removing the manifest dependency.
- [ ] Run `make build && make test && make test-wire-all`; expect exit 0.
- [x] Update Phase 3 status and commit the RxSwift removal.

### Task 7: Organize tests by subsystem (T-029)

**Files:** Move root `Tests/*.swift` into subsystem directories; modify `Package.swift`, `Makefile`, `Tests/Support/test-tiers.json`, scripts, and `Tests/TESTING.md`.

**Interfaces:** Produces stable subsystem paths and unchanged Swift test names/filters. Can run before T-026, but later ticket paths must follow its merged layout.

- [ ] Record the old-to-new path map in the ticket and use `git mv` for every move.
- [ ] Update every manifest exclusion/resource and shell/Python path reference mechanically.
- [ ] Run `make test-fast`, `make test`, and tier validation; expect exit 0 and no Swift file directly under `Tests/`.
- [ ] Commit `test: organize suite by subsystem`.

### Task 8: Finish compatibility evidence and gates (existing T-017–T-022)

**Files:** `Tests/WireCompatibility/**`, `Makefile`, `.github/workflows/ci.yml`, `docs/ROADMAP.md`.

**Interfaces:** Consumes the final async implementation. Produces approved keep/diverge/remove decisions and PR/live/nightly gates.

- [ ] Complete T-017 and T-018 reference-agent provenance and required captures.
- [ ] Complete T-019 core scenarios in supported producer/consumer directions.
- [ ] Complete T-020 lifecycle/failure live execution and T-021 IO/SensorThings decisions.
- [ ] Complete T-022 live and scheduled CI gates with retained failure artifacts.
- [ ] Run `make test-wire-all`; expect exit 0, then mark Phase 6 complete only when every matrix row has evidence or an approved decision.

### Task 9: Run WASM feasibility spike (T-030)

**Files:** Create `docs/wasm-feasibility.md`; optionally create `.devcontainer/Dockerfile.swiftwasm` and a `wasm-check` Make target; modify `docs/ROADMAP.md`.

**Interfaces:** Consumes the Rx-free dependency graph from T-028. Produces a pinned reproduction and decision, not a promised shipping platform.

- [ ] Pin and record the SwiftWasm toolchain image/digest and target triple.
- [ ] Attempt the unmodified package build and capture categorized diagnostics.
- [ ] If MQTT blocks compilation, attempt a compile-only core target behind the existing communication-client seam and record exactly what is excluded.
- [ ] Run the reproduction twice; expect the same blocker set or a successful artifact both times.
- [ ] Record feasibility, workaround, and revisit criteria; update Phase 7 and commit `docs: record SwiftWasm feasibility`.

## Dependency order and completion gate

T-023 precedes T-024 and any new public names. T-025 can run independently.
T-026 → T-027 → T-028 → T-030 is sequential. T-029 may run in parallel with
T-024/T-025 but must merge before later tickets hard-code test paths. Existing
T-017–T-022 continue alongside implementation, with their final live matrix run
after T-028. Roadmap completion requires `make docs`, `make build`, `make test`,
`make test-wire-all`, and the T-030 reproduction to match their recorded
expected outcomes.
