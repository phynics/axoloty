# Agent Instructions for Axoloty

This file is the canonical agent and contributor workflow for this repository.
The live release direction is [Axoloty v1.0 — lean, safe,
embedded-ready](https://github.com/phynics/axoloty/issues/272). The checked-in
[ROADMAP.md](./docs/ROADMAP.md) is a strategic summary; GitHub Issues and the
Roadmap Project remain authoritative for scope and status.

## Build and test

- `axoloty-tool` is the typed orchestration control plane. On Linux, invoke it through
  the lightweight root Makefile so product and ESP-IDF work stays in the
  pinned container: `make check`, `make hardware-check`, and focused wrappers.
  The image delivers a static host `axoloty-tool`, extracted to `.build-tools/axoloty-tool`; do not
  commit that generated binary. Host execution owns container and live-capture
  lifecycle while project commands still execute in the pinned image.
  On macOS, native Swift is supported through the isolated tooling package:
  `swift run --package-path Tools axoloty-tool check`. Do not run native Swift product
  builds on Linux hosts.
- The Makefile is executable documentation and a compatibility/bootstrap
  surface. New orchestration policy belongs in `AxolotyTooling`, not in Make
  recipes or new shell front controllers.
- By default, worktrees use separate mutable build directories under the
  repository- and toolchain-scoped `/tmp/coaty-swift-build/` root while sharing
  SwiftPM downloads. Every Makefile-driven operation holds a process-aware lock
  for its build directory. Coverage uses a separate sibling cache. Override `BUILD_DIR`,
  `COVERAGE_BUILD_DIR`, `SPM_CACHE_DIR`, or `BUILD_LOCK` for isolation or CI;
  CI uses its workspace-local `.build` directory with `BUILD_LOCK=0` and fails
  in preflight if that bypass is missing. `/tmp` is volatile and must not be
  the sole copy of generated output. Use `make worktree-bootstrap` to resolve
  dependencies and `make worktree-warm` only when an explicit prebuild is
  useful.
- Prefer adding an `axoloty-tool` command with a thin Make alias over adding substantive
  Make, Bash, or Python orchestration.
- Swift tests use Swift Testing only: `import Testing`, `@Test`, `#expect`,
  `#require`, and `Issue.record`. Do not add XCTest.
- Broker-backed tests must synchronize with Swift concurrency primitives or
  explicit deadlines.
- Physical ESP32-C6 checks are sporadic and opt-in. Ordinary checks must not
  probe, reserve, flash, or request privileges for a device. `hardware check`
  skips successfully when absent; `hardware require` fails when absent.
- Device test targets hardcode `/dev/ttyACM0` (or `ACM0`/`ACM1` for two-device
  tests). If devices are at different ports, override `EMBEDDED_DEVICE` (and
  `EMBEDDED_DEVICE_A`/`EMBEDDED_DEVICE_B` for two-device tests) and also add it
  to `CONTAINER_ENV_VARS` when invoking `.devcontainer/run.sh` directly. The
  container runtime must have `CONTAINER_DEVICES` set to the actual device path
  so the serial port is passed through. A Mosquitto broker must be running and
  reachable from both the host and the WiFi network the devices join; start one
  with `podman run -d --name axoloty-broker --network host axoloty-dev mosquitto
  -c /etc/mosquitto/conf.d/coatyswift.conf`. Pass `AXOLOTY_WIFI_SSID`,
  `AXOLOTY_WIFI_PASSWORD`, `AXOLOTY_MQTT_HOST`, and `AXOLOTY_MQTT_PORT` as env
  vars; WiFi credentials are compiled into a gitignored build header that is
  removed after the test — never commit them.
- Release wire evidence is generated with `make release-snapshots` on Linux or
  `axoloty-tool release snapshots` on macOS. Keep generated bundles under `.testing/`;
  only reviewed stable fixtures belong in source control.

## GitHub-centered planning workflow

The [Axoloty Roadmap](https://github.com/users/phynics/projects/5) Project is
the live roadmap. GitHub Issues are the complete planning record.

### v1 release direction

Read the v1 tracker [#272](https://github.com/phynics/axoloty/issues/272) and
its active phase gate before planning or implementing work. It defines the
north star, sequential phases, architectural invariants, non-goals, and release
criteria.

Work only from the active phase. Every v1 implementation issue must be its
sub-issue and carry the matching Project `Phase`, priority, and size. Do not
create work for a later gate or revive a superseded direction without an
approved decision linked from #272.

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
   lightweight tickets. For v1 work, link it as a sub-issue of the active
   phase gate and set its Project Phase, priority, and size. Do not create
   speculative implementation issues for later phases.
4. **Move the issue to `Ready`** on the Roadmap Project once the plan is
   approved and its phase gate is active.
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
- `AxolotyError`'s structured cases (`invalidArgument`, `decodingFailure`,
  `invalidConfiguration`, `runtime`) carry machine-readable context, not a
  free-form string. Use the existing fields (`argument`/`option`/`type` +
  `reason`) or an existing `RuntimeErrorCode` case when one fits; add a new
  `RuntimeErrorCode` case rather than force a bad fit or fall back to an ad
  hoc string. `RuntimeErrorCode` is a semver-relevant public surface —
  downstream code switches on it, so treat additions as additive-only.
- Wrap every foreign error at an Axoloty API boundary via
  `AxolotyError.caught(_:)` (or ErrorKit's `Catching.catch { ... }`) — never
  let a bare `Error` cross an Axoloty API, thrown or logged. This applies to
  absorbed/swallowed failures too: even when the boundary policy is to log
  and continue rather than propagate, wrap before logging.
- Log `ErrorKit.errorChainDescription(for:)`, not `userFriendlyMessage`, when
  diagnosing a caught error — the chain description preserves the full cause
  chain for debugging. `userFriendlyMessage` is the stable, public-facing
  string and is comparatively lossy; reserve it for user-visible text.

### Logging

- Use `LogManager.logger(.subsystem)` (see `Subsystem`), never construct a
  bare `Logger(label:)` or a second ad hoc logger for a concern that already
  has a subsystem. `LogManager`'s handler always writes to `stderr` and its
  level is controlled via `LogManager.setLevel(_:for:)` — it does not honor
  an embedding app's `LoggingSystem.bootstrap`; see `LogManager`'s doc
  comment for why.
- Follow the tiering rubric: `trace` for wire-level detail (topics,
  decoded event shape), `debug` for routine control-flow (connect/subscribe/
  disconnect housekeeping), `info` for lifecycle milestones, `notice`/
  `warning` for absorbed failures the transport recovered from on its own
  (not `.debug` — a dropped publish or ignored malformed inbound event is
  the caller's business even when it isn't fatal), `error` for a thrown-and-
  caught operation failure, `critical` for an unrecoverable config/bootstrap
  invariant. Don't invent trace/notice/critical usage beyond what's honestly
  applicable just to exercise the whole level range.
- Always pass `metadata:` for dynamic values (topic, correlation id, error
  chain, tags, etc.) — never string-interpolate them into the message. A
  message string should read the same on every call; the values that vary go
  in metadata so they're queryable, not just readable.
- When touching a multi-hop flow (a request/response pair, a connect/
  reconnect sequence, an Associate/IoValue pairing), thread and log the
  existing `correlationId`/attempt id if one already exists in that flow, or
  mint one at the point it starts if none does. Don't add a new wire field to
  carry it — correlate purely on the local/log side.

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
