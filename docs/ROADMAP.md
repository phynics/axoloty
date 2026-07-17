# Axoloty Modernization Roadmap

This document is a strategic overview. The live roadmap — with per-item status,
phase, and priority — is tracked on the
[Axoloty Roadmap](https://github.com/users/phynics/projects/5) GitHub Project.

For the agentic workflow driving planning and execution, see
[AGENTS.md](../AGENTS.md).

## Phases

### Phase 0 — Workspace, workflow & CI/container scaffolding (complete)

Container-based build/test flow, root Makefile, GitHub Actions CI, removal of
stale packaging artifacts, and this roadmap and AGENTS.md.

### Phase 1 — swift-foundation migration (complete)

Migrated Apple-platform Foundation usage to swift-foundation's portable API
surface; isolated Apple-only functionality (Bonjour) behind protocol seams.

### Phase 2 — SPM-only cleanup (complete)

SPM is the sole installation path. Jazzy replaced by DocC. A DocC catalog
exists with a landing page and getting-started article.

### Phase 3 — Dependency modernization (complete)

RxSwift → async/await/AsyncSequence/actors; CocoaMQTT → mqtt-nio;
XCGLogger → swift-log; ErrorKit adopted as `AxolotyError` base.

### Phase 4 — Linux compatibility hardening (complete)

`swift build && swift test` pass on Linux. Portable APIs preferred over
platform branching. Package builds portably without platform declarations.

### Phase 5 — Testing harness improvements (complete)

Tests organized into subsystem subfolders. Mosquitto auto-starts in containers.
Swift Testing is the sole framework. Tier ownership, coverage, and fuzz
artifacts have executable Make/CI gates.

### Phase 6 — CoatyJS protocol/version compatibility audit (in progress)

Maintaining wire-compatibility harness; auditing protocol/event versioning
against CoatyJS; per-area decisions on kept vs. dropped vs. diverged features.
Wire fixture harness, pinned/containerized reference agents, captured
reference fixtures, the live core interoperability matrix, and lifecycle and
failure compatibility are complete (T-016–T-020). The lifecycle catalog's
final disposition: 9 of 11 scenarios execute live (6 with Axoloty as the
genuine subject via a controllable TCP proxy and real broker restarts);
`qos-1`/`qos-2` are approved divergences (CoatyJS 2.4.0 hardcodes QoS 0);
legacy CoatySwift lifecycle coverage is descoped by recorded decision
(`Tests/WireCompatibility/Audit/LegacySwiftLifecycleScopeDecision.md`).

The IO/SensorThings compatibility decision (T-021, #31) is recorded: the IO
reference runner, offline wire-format evidence, and a live modern→JS
Associate scenario are in place, and the keep/diverge/remove decisions are
documented in
`Tests/WireCompatibility/Audit/IOAndSensorThingsDecisions.md`. Two defects
were found and recorded as intentional divergences rather than silently
normalized: Axoloty's `handleAssociate` force-unwraps the optional
`isExternalRoute` (CoatyJS omits it, so an Axoloty actor traps), and the
IoValue wire format wraps the value under `payload` while CoatyJS publishes
the bare value. Several scenarios (raw IoValue capture, external route,
fan-out, SensorThings fixtures) are honestly marked not-yet-tested pending
follow-up captures; legacy CoatySwift IO directions are descoped by recorded
decision (`LegacySwiftIOScopeDecision.md`). Remaining in this phase: the
compatibility CI gates (T-022, #32) wiring the new offline suites into the PR
tier and the live IO runner into the nightly tier.

### Phase 7 — Runtime correctness (EventHub/streaming + IO routing)

Closes out correctness gaps left by the Phase 3 RxSwift → async/await
migration: lost/dropped events, unstructured task spawning breaking MQTT
ordering, stream lifecycle leaks, and IO-routing data-clump cleanup. Tracked
under [#135](https://github.com/phynics/Axoloty/issues/135).

### Phase 8 — Wire test infrastructure

Replaces the Python wire-compatibility harness with an npx-runnable Node CLI
plus Swift Testing verification, and fills in remaining JS → modern live
scenario coverage. Tracked under
[#120](https://github.com/phynics/Axoloty/issues/120), sequenced as part of
[#135](https://github.com/phynics/Axoloty/issues/135).

---

The modernization roadmap epic ([#43](https://github.com/phynics/Axoloty/issues/43))
is closing out: T-021 (#31) is complete with its decisions recorded, leaving
only the compatibility CI gates T-022 (#32). Phases 7–8 continue under a new epic,
[#135](https://github.com/phynics/Axoloty/issues/135) (Post-Modernization
Roadmap), per
`docs/superpowers/plans/2026-07-17-post-modernization-roadmap.md`. WASM
exploration (#127), Embedded Swift (#96), and the IO routing bounded-cost
epic (#115) remain tracked separately and are not gated on #135.
