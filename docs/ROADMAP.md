# CoatySwift Modernization Roadmap

This is a living document tracking the phased modernization of this
[phynics/coaty-swift](https://github.com/phynics/coaty-swift) fork. It is
intentionally a roadmap, not a spec — see `../AGENTS.md` for the
specs → tickets → worktree workflow used to actually plan and execute each
piece of work.

Phases are ordered by dependency, not necessarily by priority. Later phases
may start before earlier ones fully close out.

## Phase 0 — Workspace, workflow & CI/container scaffolding (in progress)

**Why:** The development machine (NixOS) cannot run the native Swift
toolchain directly — dynamic linking fails outside of a container — so a
podman-based build/test/docs flow has to exist before any other phase can be
verified locally or in CI.

**What this phase covers:**
- A `.devcontainer/Dockerfile` and `.devcontainer/devcontainer.json` providing
  a containerized Swift toolchain.
- A root `Makefile` with `build`, `test`, `shell`, and `docs` targets, all
  invoking `podman` under the hood.
- A `.github/workflows/ci.yml` GitHub Actions workflow driving the same
  container-based build/test flow.
- Removal of stale packaging/doc artifacts (`CoatySwift.podspec`,
  `.jazzy.yaml`, and the entire legacy `docs/` tree — Jekyll site, Jazzy
  HTML output, and legacy guides, to be recreated as a DocC catalog in
  Phase 2) and a cleaned up `.gitignore`.
- This roadmap, `../AGENTS.md`, and `../CLAUDE.md` establishing the agent-facing
  workflow and documentation entry points.

**Done when:**
- [ ] `make build` and `make test` succeed on the NixOS dev machine via podman.
- [ ] CI runs the same containerized flow on every push/PR.
- [ ] No stale CocoaPods/Jazzy artifacts remain in the repository.
- [ ] `docs/ROADMAP.md`, `../AGENTS.md`, `../CLAUDE.md` exist and are consistent with
      each other.

## Phase 1 — swift-foundation migration (Linux build blocker)

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
- [ ] The `CoatySwift` target compiles against swift-foundation on Linux
      (link/test failures from *other* dependencies are acceptable at this
      stage; Foundation-related compile errors are not).
- [ ] Apple-only Foundation/framework usage is isolated behind explicit
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
- Recreate project documentation from scratch as a DocC catalog: the old
  `docs/` directory (Jekyll GitHub Pages site, Jazzy HTML output, and the
  legacy developer guide / tutorial / migration guide) has been removed
  entirely in Phase 0; long-form guides come back as DocC articles alongside
  the API docs rather than a separate Jekyll site.

**Done when:**
- [ ] SPM is the only documented installation/consumption path.
- [ ] API documentation is generated via DocC, not Jazzy.
- [ ] A DocC catalog exists with at least a landing page and a getting-started
      article, replacing the removed `docs/` site.
- [ ] `CoatySwift.podspec`, `.jazzy.yaml`, and the `docs/` directory no
      longer exist in the repo (tracked under Phase 0's cleanup, verified
      here).

## Phase 3 — Dependency modernization

**Why:** RxSwift, CocoaMQTT, and XCGLogger were reasonable choices in 2019
but are now legacy relative to Swift's native structured-concurrency and
logging story, and they are a primary source of platform/portability risk
(see Phase 4 and Phase 7).

**Status:** CocoaMQTT and XCGLogger are gone (T-005, T-006). The real,
non-quarantined `swift build` now fails on exactly one remaining cause —
RxSwift 5.1.3's `AtomicInt: NSLock` inheritance, incompatible with the
Swift 6.3.3 toolchain — confirmed via a clean container build with zero
errors elsewhere. RxSwift removal (T-007/T-008) is the last blocker to a
fully green Linux build.

**What this phase covers:**
- Remove RxSwift in favor of Swift 6.4 structured concurrency: async/await,
  `AsyncStream`/`AsyncSequence` in place of `Observable`, actors for shared
  mutable state (`CommunicationManager`, `Container`). RxSwift usage today is
  concentrated in:
  - `Source/Communication/Manager/*` (`CommunicationManager`,
    `CM+Observe`/`CM+Publish`/`CM+Util`)
  - `Source/IORouting/*` (`IoRouter`, `IoActorController`,
    `IoSourceController` — note `IoRouter.swift` currently relies on a
    transitive RxSwift import via `.subscribe(onNext:)` without importing
    RxSwift itself, which is fragile and should be fixed regardless of
    timing)
  - `Source/SensorThings/*ObserverController*`
  - `Source/Controller/ObjectLifecycleController.swift`
  - `Source/Runtime/Controller.swift` and `Container.swift`
  - the MQTT client integration files
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
  existing `CoatySwiftError` enum onto it is a separate, explicit decision
  (not assumed) — see the ticket for scope.

**Done when:**
- [ ] No source file imports RxSwift; all reactive-style APIs are expressed
      with async/await, `AsyncSequence`, or actors.
- [ ] `ErrorKit` is a Package.swift dependency and all error types added
      after its adoption conform to `Throwable`; a decision is recorded on
      whether/how `CoatySwiftError` itself migrates.
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

## Phase 4 — Linux compatibility hardening

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
- [ ] `swift build && swift test` pass on Linux inside the devcontainer/CI
      image with no skipped test targets.
- [ ] `Package.swift` accurately declares supported platforms including
      Linux, or the package builds portably without needing to.
- [ ] `#if os(Linux)` conditionals are limited to genuinely
      platform-specific code paths.

## Phase 5 — Testing harness improvements

**Why:** The current test suite assumes an MQTT broker is already listening
on `localhost:1883` on the host machine, which doesn't hold inside a
container or CI runner, and the flat `Tests/` layout doesn't scale as
Phase 3/4 work adds coverage.

**What this phase covers:**
- Restructure `Tests/` into subfolders by subsystem (communication, IO
  routing, sensor things, runtime, etc.) instead of one flat directory.
- Run a real MQTT broker as a sidecar container in the devcontainer and in
  CI, rather than assuming one is already reachable at `localhost:1883`.
- Consider migrating to the `swift-testing` framework as it matures, instead
  of (or alongside) `XCTest`.

**Done when:**
- [ ] Tests are organized into subsystem subfolders.
- [ ] CI and the devcontainer both start an MQTT broker sidecar
      automatically; no test depends on a broker pre-existing on the host.
- [ ] A decision is recorded on adopting `swift-testing`, with at least a
      pilot conversion if adopted.

## Phase 6 — CoatyJS protocol/version compatibility audit

**Why:** CoatySwift's value partly comes from interoperating with CoatyJS
agents on the wire, but this fork does not need full feature parity with
CoatyJS going forward — an explicit, scoped decision is needed on what
compatibility is actually worth preserving.

**What this phase covers:**
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
- Explore building CoatySwift with the SwiftWasm toolchain.
- Identify which Phase 3 dependency choices block a WASM build — the
  networking/MQTT client is the most likely blocker (raw socket access,
  TLS, and threading models don't map cleanly to WASM/WASI today).

**Done when:**
- [ ] A SwiftWasm build attempt has been made and its blockers documented.
- [ ] The specific dependency (or dependencies) blocking WASM are
      identified, with either a workaround or an explicit "not feasible yet"
      conclusion recorded.
