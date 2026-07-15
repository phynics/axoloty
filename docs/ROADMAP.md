# Axoloty Modernization Roadmap

This is a living document tracking the phased modernization of this
[phynics/coaty-swift](https://github.com/phynics/coaty-swift) fork. It is
intentionally a roadmap, not a spec — see `../AGENTS.md` for the
specs → tickets → worktree workflow used to actually plan and execute each
piece of work.

Phases are ordered by dependency, not necessarily by priority. Later phases
may start before earlier ones fully close out.

## Recent completed slices

- **T-035** (`d8a9519`): audited all seven direct SwiftPM dependencies and
  documented freshness, licensing, platform, usage, and follow-up paths in
  `docs/dependency-audit.md`.
- **T-045** (`da42901`): made the test-tier contract executable, mapped every
  maintained Python/shell self-test, and separated harness checks from wire
  scenarios.
- **T-047** (`89a886e`): added containerized `make coverage` reporting with a
  measured 39.55% Source/ baseline and a 1.0 percentage-point ratchet.
- **T-049** (`f1d36b6`): added scheduled/manual bounded fuzz campaigns with
  finalized artifact retention and nightly-tier registration.

## Phase 0 — Workspace, workflow & CI/container scaffolding (complete)

**Why:** The development machine (NixOS) cannot run the native Swift
toolchain directly — dynamic linking fails outside of a container — so a
podman-based build/test flow has to exist before any other phase can be
verified locally or in CI.

**What this phase covers:**
- A `.devcontainer/Dockerfile` and `.devcontainer/devcontainer.json` providing
  a containerized Swift toolchain.
- A root `Makefile` with containerized `build`, `test`, and `shell` targets;
  a DocC `docs` target is tracked in Phase 2.
- A `.github/workflows/ci.yml` GitHub Actions workflow driving the same
  container-based build/test flow.
- Removal of stale packaging/doc artifacts (`CoatySwift.podspec`,
  `.jazzy.yaml`, and the legacy Jekyll/Jazzy documentation — to be recreated
  as a DocC catalog in Phase 2) and a cleaned up `.gitignore`.
- This roadmap and `../AGENTS.md` establishing the agent-facing workflow and
  documentation entry points.

**Done when:**
- [x] `make build` and `make test` succeed on the NixOS dev machine via podman.
- [x] CI runs the same containerized flow on every push/PR.
- [x] No stale CocoaPods/Jazzy artifacts remain in the repository.
- [x] `docs/ROADMAP.md` and `../AGENTS.md` exist and are consistent with each
      other.

## Phase 1 — swift-foundation migration (complete)

**Why:** The codebase currently relies on Apple-platform Foundation behavior
and Apple-only frameworks; migrating to
[swift-foundation](https://github.com/swiftlang/swift-foundation) is the
prerequisite for building on Linux at all. Nothing in Phase 4 (Linux
hardening) can go green until this lands, so it comes before any other
dependency or refactoring work.

**What this phase covers:**
- Audit every `import Foundation` usage for APIs that don't exist or behave
  differently under swift-foundation on Linux (e.g. `NetService`/Bonjour in
  `Source/Communication/Client/`, timer/run-loop usage, `JSONEncoder`
  behavioral differences).
- Migrate to swift-foundation's portable API surface
  (`FoundationEssentials`/`FoundationInternationalization`), isolating any
  genuinely Apple-only functionality (Bonjour discovery) behind protocol
  seams so the core builds without it.
- Record which Foundation-dependent features are dropped vs. reimplemented
  portably.

**Done when:**
- [x] The `CoatySwift` target compiles against swift-foundation on Linux
      (link/test failures from *other* dependencies are acceptable at this
      stage; Foundation-related compile errors are not).
- [x] Apple-only Foundation/framework usage is isolated behind explicit
      seams with a recorded keep/drop decision per feature.

## Phase 2 — SPM-only cleanup

**Why:** The project already ships via Swift Package Manager; keeping a
parallel CocoaPods packaging path (podspec, Jazzy-generated docs meant to
back a CocoaPods release) is dead weight that actively causes the
version/platform drift documented in `../README.md` today.

**What this phase covers:**
- Confirm no remaining references to CocoaPods installation anywhere in the
  docs or `../README.md`.
- Replace Jazzy as the API-documentation generator with DocC, wired into
  `make docs`.
- Recreate project documentation from scratch as a DocC catalog: the legacy
  Jekyll GitHub Pages site, Jazzy HTML output, and developer guides were
  removed in Phase 0; long-form guides come back as DocC articles alongside
  the API docs rather than a separate Jekyll site.

**Done when:**
- [x] SPM is the only documented installation/consumption path.
- [x] API documentation is generated via DocC, not Jazzy.
- [x] A DocC catalog exists with at least a landing page and a getting-started
      article, replacing the removed `docs/` site.
- [x] `CoatySwift.podspec` and `.jazzy.yaml` no longer exist in the repo;
      the legacy generated/Jekyll documentation was removed in Phase 0.

## Phase 3 — Dependency modernization

**Why:** RxSwift, CocoaMQTT, and XCGLogger were reasonable choices in 2019
but are now legacy relative to Swift's native structured-concurrency and
logging story, and they are a primary source of platform/portability risk
(see Phase 4 and Phase 7).

**Status:** CocoaMQTT and XCGLogger are gone (T-005, T-006), the dependency
audit is complete (T-035), ErrorKit is adopted for `AxolotyError` (T-025), and
the RxSwift migration (T-026 through T-028, T-040, T-050, T-051) is complete.
Communication, runtime, IO routing, and SensorThings now use EventHub streams
and owned Swift concurrency tasks.

**T-026** (Swift 6.3 event-stream foundation) → **T-027** (event-model
snapshots) → **T-039** (communication manager actor migration) →
**T-040 / T-050 / T-051** (controller, IO routing, and SensorThings
migration) → **T-028** (final RxSwift removal, completed).

T-039's subscription-coordinator slice is implemented: MQTT topic reference
counts and reconnect replay are actor-owned, subscription acknowledgements are
awaited before manager readiness, and async event snapshots drive lifecycle
through `EventHub`. Distributed logging, object-lifecycle, IO-routing, and
SensorThings consumers use owned tasks and cancellation.

**What this phase covers:**
- Replace the former RxSwift observation and disposal boundaries with
  Swift 6.3 structured concurrency: async/await, `AsyncStream`/`AsyncSequence`,
  EventHub snapshots, actors, and owned cancellation tasks. The migration is
  complete across communication, runtime, IO routing, SensorThings, and MQTT
  integration; the paths listed in the original ticket are retained in the
  ticket history for traceability only.
- Evaluate CocoaMQTT's Linux/WASM viability — it transitively pulls in
  Starscream and `swift-nio-zlib-support`, both of uncertain Linux/WASM
  status — against alternative MQTT client libraries.
- Replace XCGLogger with `swift-log`.
- Adopt [ErrorKit](https://github.com/FlineDev/ErrorKit) for error handling
  going forward, replacing ad hoc `Error` enums/`NSError` usage with its
  `Throwable`/`Catching` protocols. Confirmed Linux/WASI-compatible (its
  `Package.swift` conditionally depends on swift-crypto specifically for
  `.linux`/`.wasi`/`.android`/`.windows` — evidence of real, tested
  cross-platform support, not just an Apple-platform library), and requires
  swift-tools-version 6.0, matching this fork's direction. New error types
  written from this point on should conform to `Throwable`; migrating the
  existing `AxolotyError` enum onto it is a separate, explicit decision
  (not assumed) — see the ticket for scope.

**Done when:**
- [x] No source or test file imports RxSwift; all reactive-style APIs are expressed
      with async/await, `AsyncSequence`, or actors.
- [x] `Package.swift`, `Package.resolved`, and the legacy runner contain no
      RxSwift dependency or checkout.
- [x] `ErrorKit` is a Package.swift dependency and `AxolotyError` conforms to
      `Throwable` with a tested user-facing message; broader boundary
      migration remains part of T-031.
- [x] A decision is recorded on CocoaMQTT vs. an alternative MQTT client,
      with Linux/WASM viability as the deciding factor. ✅ Done (T-005,
      `mqtt-nio`) — CocoaMQTT and its transitive Obj-C dependency
      (`MqttCocoaAsyncSocket`, the original Linux build blocker) are gone;
      full behavioral parity preserved (last-will, QoS, TLS, broker-candidate
      fallback, `cleanSession` semantics) behind the same `CommunicationClient`
      protocol, so `CommunicationManager` needed no changes.
- [x] XCGLogger is fully replaced by `swift-log`. ✅ Done (T-006) — also
      incidentally fixed `AppleSystemLogDestination`, itself an Apple-only
      Linux blocker.

## Phase 4 — Linux compatibility hardening (complete)

**Why:** The container/CI scaffolding from Phase 0 is only useful if the
package actually builds and tests cleanly on Linux inside it; today Linux
support is untested and undeclared.

**What this phase covers:**
- Get `swift build && swift test` fully green inside the container.
- Add an explicit Linux platform declaration to `Package.swift` (or confirm
  none is needed once dependencies are Linux-clean).
- Minimize `#if os(Linux)` conditionals — prefer portable APIs over
  platform branching wherever the Phase 3 dependency choices allow it.

**Done when:**
- [x] `swift build && swift test` pass on Linux inside the devcontainer/CI
      image with no skipped test targets.
- [x] `Package.swift` accurately declares supported platforms including
      Linux, or the package builds portably without needing to.
- [x] `#if os(Linux)` conditionals are limited to genuinely
      platform-specific code paths.

## Phase 5 — Testing harness improvements (complete)

**Why:** The current test suite assumes an MQTT broker is already listening
on `localhost:1883` on the host machine, which doesn't hold inside a
container or CI runner, and the flat `Tests/` layout doesn't scale as
Phase 3/4 work adds coverage.

**What this phase covers:**
- Restructure `Tests/` into subfolders by subsystem (communication, IO
  routing, sensor things, runtime, etc.) instead of one flat directory.
- Start a real MQTT broker automatically in containerized test runs, rather
  than assuming one is already reachable at `localhost:1883`.
- Adopt the toolchain-provided `swift-testing` framework as the sole Swift test
  framework; XCTest is not retained.
- Keep tier ownership executable and retain reproducible fuzz and coverage
  evidence in CI.

**Status:** Swift Testing migration and test organization are complete. The
canonical test target starts Mosquitto automatically inside its test
container; support-tool self-tests, coverage policy, and nightly fuzz evidence
are separate executable gates.

**Done when:**
- [x] Tests are organized into subsystem subfolders (T-029).
- [x] CI and local containerized tests start an MQTT broker automatically;
      no test depends on a broker pre-existing on the host.
- [x] Swift Testing adoption is recorded and the Swift test target is migrated
      without an XCTest compatibility layer.
- [x] Test-tier ownership, source coverage, and scheduled fuzz artifacts have
      executable Make/CI gates (T-045, T-047, T-049).

## Phase 6 — CoatyJS protocol/version compatibility audit (in progress)

**Why:** Axoloty's value partly comes from interoperating with CoatyJS
agents on the wire, but this fork does not need full feature parity with
CoatyJS going forward — an explicit, scoped decision is needed on what
compatibility is actually worth preserving.

**What this phase covers:**
- Maintain the fixture, capture, reference-agent, and live-scenario harness
  under `Tests/WireCompatibility/`, with an offline compatibility gate in CI.
- Audit the current communication protocol / event versioning against the
  CoatyJS implementation.
- Decide, event type by event type and feature by feature, what must remain
  wire-compatible with CoatyJS vs. what can be dropped or diverge in this
  fork.

**Done when:**
- [ ] A written compatibility decision exists per protocol area (kept vs.
      dropped vs. diverged).
- [ ] Source and tests reflect only the compatibility surface that was
      decided to be kept.

## Phase 7 — WASM exploration

**Why:** Running Coaty agents compiled to WebAssembly (e.g. in-browser or
in constrained sandboxes) is an attractive long-term target, but it's
gated entirely on the dependency choices made in Phase 3.

**What this phase covers:**
- Explore building Axoloty with the SwiftWasm toolchain.
- Identify which Phase 3 dependency choices block a WASM build — the
  networking/MQTT client is the most likely blocker (raw socket access,
  TLS, and threading models don't map cleanly to WASM/WASI today).

**Done when:**
- [ ] A SwiftWasm build attempt has been made and its blockers documented.
- [ ] The specific dependency (or dependencies) blocking WASM are
      identified, with either a workaround or an explicit "not feasible yet"
      conclusion recorded.
