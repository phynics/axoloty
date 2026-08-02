# Agent Instructions for Axoloty

Canonical agent/contributor workflow. Current release: [Axoloty 0.2.0](https://github.com/phynics/axoloty/releases/tag/v0.2.0), development checkpoint. [ROADMAP.md](./docs/ROADMAP.md) = strategic summary. GitHub Issues = complete planning record.

## Build and test

- `axoloty-tool` = typed orchestration control plane. Linux: invoke through root Makefile, product/ESP-IDF work stays in pinned container. `make check`, `make hardware-check`, focused wrappers. Binary prebuilt in container image at `/opt/axoloty/bin/axoloty-tool`, runs in-container via `.devcontainer/run.sh`. Not extracted to host. macOS: native Swift via isolated tooling package: `swift run --package-path Tools axoloty-tool check`. No native Swift product builds on Linux.
- Makefile = executable documentation + compatibility/bootstrap surface. New orchestration policy belongs in `AxolotyTooling`, not Make recipes or shell front controllers.
- **Building and testing from a worktree on Linux:** the host Swift toolchain is too old (Package.swift requires 6.3); all builds go through the pinned container via `.devcontainer/run.sh`. The Makefile sets the required env vars (`CONTAINER_RUNTIME`, `IMAGE`, `BUILD_DIR`, `SPM_CACHE_DIR`) and calls `run.sh` — prefer Make targets (`make build`, `make test`, `make test-tooling`) over calling `run.sh` directly. For targeted builds/tests not covered by a Make target, call `run.sh` with the same env vars the Makefile would set:
  ```sh
  CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
  BUILD_DIR=/tmp/coaty-swift-build/axoloty/swift-6.3-linux/worktrees/<worktree-name>/debug \
  SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
  .devcontainer/run.sh swift build --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --product <product>
  ```
  For tests, replace `swift build` with `swift test --filter <TestSuiteName>`. The `--disable-automatic-resolution` flag is mandatory (Package.resolved is checked in; resolve changes require `make resolve`). The `--cache-path /workspace/.swiftpm-cache` flag maps to the SPM cache mount inside the container.
- **Swift 6 strict concurrency gotchas when importing Axoloty:** (1) Axoloty defines a `Task` model type (`Source/Model/Core Types/Task.swift`) that shadows `_Concurrency.Task` — always use `_Concurrency.Task { }`, `_Concurrency.Task.sleep(for:)`, `_Concurrency.Task.isCancelled` in code that imports `Axoloty`. (2) C globals like `stdout` are not concurrency-safe — use `isatty(1)` instead of `fileno(stdout)`. (3) `JSONEncoder` on Linux escapes `/` as `\/` by default — prefer `JSONSerialization`-based assertions over raw string matching in tests.
- Worktrees use separate mutable build dirs under `/tmp/coaty-swift-build/` root, share SwiftPM downloads. Every Makefile operation holds process-aware lock for its build dir. Coverage uses separate sibling cache. Override `BUILD_DIR`, `COVERAGE_BUILD_DIR`, `SPM_CACHE_DIR`, or `BUILD_LOCK` for isolation/CI. CI uses workspace-local `.build` with `BUILD_LOCK=0`, fails in preflight if bypass missing. `/tmp` volatile — never sole copy of generated output. `make worktree-bootstrap` = resolve deps. `make worktree-warm` = explicit prebuild only.
- Prefer `axoloty-tool` command (in-container) + thin Make alias over substantive Make/Bash/Python orchestration.
- Local services use `ax serve mqtt|mcp|dev`; Linux `make serve-*` targets are thin in-container wrappers. Keep MCP HTTP loopback-only and use explicit `--transport`.
- Swift tests use Swift Testing only: `import Testing`, `@Test`, `#expect`, `#require`, `Issue.record`. No XCTest.
- Broker-backed tests must synchronize with Swift concurrency primitives or explicit deadlines.
- ESP32-C6 checks sporadic, opt-in. Ordinary checks must not probe/reserve/flash/request device privileges. `hardware check` skips when absent; `hardware require` fails when absent.
- Device test targets hardcode `/dev/ttyACM0` (or `ACM0`/`ACM1` for two-device tests). Override `EMBEDDED_DEVICE` (and `EMBEDDED_DEVICE_A`/`EMBEDDED_DEVICE_B` for two-device), add to `CONTAINER_ENV_VARS` when invoking `.devcontainer/run.sh` directly. Container runtime needs `CONTAINER_DEVICES` set to actual device path for serial pass-through. Mosquitto broker must run and be reachable from host + device WiFi network: `podman run -d --name axoloty-broker --network host axoloty-dev mosquitto -c /etc/mosquitto/conf.d/coatyswift.conf`. Pass `AXOLOTY_WIFI_SSID`, `AXOLOTY_WIFI_PASSWORD`, `AXOLOTY_MQTT_HOST`, `AXOLOTY_MQTT_PORT` as env vars. WiFi credentials compiled into gitignored build header, removed after test — never commit.
- Release wire evidence: `make release-snapshots` (Linux) or `axoloty-tool release snapshots` (macOS). Checkpoint validation: `make checkpoint` (ordinary) or `make checkpoint-hardware` (requires device). Generated bundles under `.testing/`; only reviewed stable fixtures in source control.
- Full live wire suite (`make test-wire-live`) runs longer than ordinary checks and can exceed 20 minutes. Use an extended timeout of at least 30 minutes locally and in agent tooling, and 60 minutes in cold CI; do not treat a shorter harness timeout as a test failure.

## GitHub-centered planning workflow

GitHub Issues = complete planning record.

### Planning

Search existing issues before filing (`gh issue list`, `gh issue view`). Backlog has `T-NNN — <title>` issues migrated from old ticket system; title-only search can miss — also grep issue bodies. Filing duplicate wastes round trip.

Create/refine GitHub Issue: Work Plan template for structured tasks, Bug report/Feature request for lightweight tickets.

### Agentic loop

1. **Fetch `origin/main` before branching.** This file can change between sessions. `git fetch origin main`, diff against it first.
2. **Search existing issues** (`gh issue list`, `gh issue view`).
3. **Create/refine GitHub Issue.**
4. **Implement from dedicated worktree:**
   ```sh
   git worktree add .worktree/<#issue-number>-<slug> -b <#issue-number>-<slug> main
   ```
5. **Open PR** targeting `main` with `Closes #<issue-number>` in description.
6. **Merge PR**; issue closes via `Closes` keyword.

### Historical tickets

Historical T-### tickets migrated to GitHub Issues, T-ID retained in title/body. See `.github/MIGRATION_LEDGER.md` for mapping.

### Session hygiene

- **Verify `pwd` + `git branch --show-current` before every commit/push.** Shell working dir can silently reset to main checkout between tool invocations. Commit there lands on wrong branch. Cheap to check every time.
- **One fix per PR, each rooted in local repro.** Multi-layer failure: reproduce + verify each bug locally before fix, land each as own commit/PR explaining what earlier fix exposed. Bundling unrelated root causes = hard to tell which fix mattered.
- **Filing new issue proactively (not asked) = scope creep**, even when clearly correct. Surface to requester, let them decide, unless standing authorization granted. Once they say proceed = authorization for that one issue only.

## Code conventions

### Source files

- New comment-capable source files need header, using first publication year, never change later:
  ```swift
  // Copyright (c) <year> <contributor>. Licensed under the MIT License.
  ```
- Follow repository SwiftLint configuration.
- Every public type/property/method/initializer/protocol needs DocC comment. Document parameters, returns, errors when applicable; use double-backtick symbol links; update public API documentation with API.

### Errors

- Use ErrorKit for package errors. Package-defined errors conform to `Throwable`, provide stable `userFriendlyMessage`. Prefer `AxolotyError` unless distinct public boundary needs another type.
- No bare `Error`, encoding/decoding, or dependency errors from Axoloty API. Convert to Axoloty `Throwable` with actionable context.
- Failure tests assert error category + `userFriendlyMessage`. Preserve public signatures unless approved plan authorizes breaking change.
- `AxolotyError` structured cases (`invalidArgument`, `decodingFailure`, `invalidConfiguration`, `runtime`) carry machine-readable context, not free-form string. Use existing fields (`argument`/`option`/`type` + `reason`) or existing `RuntimeErrorCode` case. Add new `RuntimeErrorCode` case rather than force bad fit or fall back to ad hoc string. `RuntimeErrorCode` = semver-relevant public surface — downstream code switches on it, treat additions as additive-only.
- Wrap every foreign error at Axoloty API boundary via `AxolotyError.caught(_:)` (or `Catching.catch { ... }`). Never let bare `Error` cross Axoloty API, thrown or logged. Applies to absorbed/swallowed failures too: even when policy = log and continue, wrap before logging.
- Log `ErrorKit.errorChainDescription(for:)`, not `userFriendlyMessage`, when diagnosing caught error. Chain description preserves full cause chain for debugging. `userFriendlyMessage` = stable, public-facing string, comparatively lossy. Reserve for user-visible text.

### Logging

- Use `LogManager.logger(.subsystem)` (see `Subsystem`). Never construct bare `Logger(label:)` or second ad hoc logger for concern that already has subsystem. `LogManager` handler always writes to `stderr`, level controlled via `LogManager.setLevel(_:for:)`. Does not honor embedding app's `LoggingSystem.bootstrap`; see `LogManager` doc comment.
- Tiering: `trace` = wire-level detail (topics, decoded event shape), `debug` = routine control-flow (connect/subscribe/disconnect housekeeping), `info` = lifecycle milestones, `notice`/`warning` = absorbed failures transport recovered from on its own (not `.debug` — dropped publish or ignored malformed inbound event = caller's business even when not fatal), `error` = thrown-and-caught operation failure, `critical` = unrecoverable config/bootstrap invariant. Don't invent usage beyond what's honestly applicable.
- Always pass `metadata:` for dynamic values (topic, correlation id, error chain, tags). Never string-interpolate into message. Message string should read same on every call; varying values go in metadata = queryable, not just readable.
- Multi-hop flow (request/response pair, connect/reconnect sequence, Associate/IoValue pairing): thread + log existing `correlationId`/attempt id if one exists in flow, or mint one at start if none. Don't add new wire field — correlate purely on local/log side.

### Commits

- Use Conventional Commits.
- Commit with this checkout's configured identity. Never add bot co-author trailers.

### Wire compatibility

Axoloty targets wire compatibility with pinned CoatyJS reference agent (`Tests/WireCompatibility/ReferenceAgents/`). Reference = source of truth for wire shape.

- **Match CoatyJS where possible.** Axoloty/CoatyJS disagree on wire detail (field presence, payload wrapping, encoding overload): default = change Axoloty to match reference, not record difference as accepted. Captured discrepancy = defect to fix, not divergence to ratify — unless matching impossible or more harmful than breaking.
- **Remain compatible despite divergence.** Unavoidable divergence: Axoloty must still tolerate peer's wire shape. Decode optional fields defensively (never force-unwrap field peer may omit), accept bare payload external producer sends. Trapping on peer's legitimate omission = bug, not compatibility boundary.
- **No accidental divergences.** Wire-format or field-presence change requires regression test locking in new behavior + update to `Tests/WireCompatibility/CompatibilityMatrix.md`. Record only deliberate, unavoidable divergences (e.g. platform constraint like CoatyJS hardcoding QoS 0) with capture evidence + linked decision.
