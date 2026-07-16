# Axoloty Modernization Roadmap

This document is a strategic overview. The live roadmap — with per-item status,
phase, and priority — is tracked on the
[Axoloty Roadmap](https://github.com/phynics/axoloty/projects) GitHub Project.

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

### Phase 7 — WASM exploration

Exploring SwiftWasm build; identifying dependency blockers for WASM target.
