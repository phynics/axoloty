# Build and test tooling

`axoloty-tool` is Axoloty's typed command-line control plane. Its plans, process results,
hardware outcomes, and JSON manifests are defined in Swift and tested with
Swift Testing. The principal root Make targets forward to `axoloty-tool`; the Makefile
also retains compatibility recipes for specialized evidence workflows that do
not belong to the canonical offline check.

## Platform entry points

Linux product and ESP-IDF work is containerized:

```sh
make check
make axoloty-tool AXOLOTY_TOOL_ARGS='wire verify'
make hardware-check
make release-snapshots
```

The container image carries a prebuilt `axoloty-tool` at
`/opt/axoloty/bin/axoloty-tool`. Make targets invoke it inside the
container via `.devcontainer/run.sh`; the binary is not extracted to the
host. All build, test, and lint commands execute directly in-container.

macOS uses its pinned native Swift toolchain:

```sh
swift run --package-path Tools axoloty-tool check
```

The macOS plan runs host build, lint, tooling tests, and offline wire fixtures.
The Linux plan adds ESP32-C6 cross-compilation and linker verification. Neither
plan starts MQTT or accesses hardware.

## Command tiers

| Command | MQTT | Hardware | Purpose |
|---|:---:|:---:|---|
| `axoloty-tool check` / `axoloty-tool test offline` | no | no | Deterministic platform plan |
| `axoloty-tool test integration` | local | no | Broker-backed transport behavior |
| `axoloty-tool wire verify` | no | no | Direct fixture and snapshot verification |
| `axoloty-tool wire capture` | local | no | Live reference-agent capture (host-side orchestration) |
| `axoloty-tool embedded build` | no | no | ESP32-C6 cross-compilation on Linux |
| `axoloty-tool embedded verify` | no | no | Build plus linker contract verification |
| `axoloty-tool hardware check` | no | optional | Run when attached; otherwise structured skip |
| `axoloty-tool hardware require` | no | required | Explicit device/release gate |
| `axoloty-tool release snapshots` | no | no | Generate and verify an immutable wire bundle |

Broker-backed transport, live CoatyJS capture, coverage, and long fuzz campaigns
retain focused Make targets while their existing evidence contracts remain in
place. Wire parsing correctness belongs to the offline tier; MQTT tests only
transport behavior.

## Structured output

`axoloty-tool` writes its result JSON to standard output and child/bootstrap diagnostics
to standard error. Check output uses schema version 1 and records the platform,
stable node names, statuses, exit codes, and captured streams. Failed
prerequisites cause dependent nodes to be reported as skipped while independent
nodes continue, so a single invocation describes the complete planned pass.

Hardware results record `passed`, `skipped`, or `failed`, the selected device
path, and a reason. `hardware check` returns success for an absent device;
`hardware require` returns failure. Set `AXOLOTY_DEVICE` or pass `--device` to
select a path other than `/dev/ttyACM0`.

## Container image and caches

The development image contains Swift, SwiftLint, Mosquitto, ESP-IDF, initialized
ESP-IDF submodules, the ESP32-C6 toolchain, and flashing tools. Once the image
and SwiftPM dependencies are acquired, offline checks do not initialize ESP-IDF
submodules on demand.

SwiftPM downloads use `SPM_CACHE_DIR`. Mutable build artifacts default to a
per-worktree `BUILD_DIR` and are guarded by a process-aware `flock` unless isolated CI sets
`BUILD_LOCK=0`. CI always uses workspace-local mutable directories. Generated
evidence that must survive a run belongs under `.testing/`, never only in
volatile `/tmp`.

## Release snapshots

`axoloty-tool release snapshots` copies the reviewed wire captures into
`.testing/release-snapshots`, records byte hashes, scenario and reference-agent
metadata, normalization profiles, repository/toolchain/image provenance, and
then verifies the bundle without MQTT. `AXOLOTY_SNAPSHOT_SOURCE` and
`AXOLOTY_SNAPSHOT_OUTPUT` override the source and destination for a release
workflow. The bundle is generated evidence; stable fixtures enter source
control only through normal review and the compatibility-matrix policy.
Pass a persisted or downloaded bundle to `axoloty-tool wire verify PATH` to rerun both
the Swift semantic fixture contract and the bundle's hash/metadata checks.
Snapshot output overrides must remain below `.testing/` and cannot overlap the
source captures.

## Adding tooling

Add orchestration behavior to the `AxolotyTooling` target with injected process,
filesystem, environment, clock, or platform boundaries as applicable. Add
Swift Testing coverage and expose the behavior through `axoloty-tool`; add a short Make
alias only when Linux contributors need a documented container entry point.
Do not add a new Bash or Python front controller.

## `axoloty-inspect` — MQTT object inspector

`axoloty-inspect` is a separate executable product that connects to a live
MQTT broker through Axoloty and inspects Coaty objects without writing a
custom agent. It has two subcommands:

- **`catalog`** — passively observes Advertise/Deadvertise events and
  maintains an in-memory object catalogue. Publishes no Coaty events.
- **`discover`** — sends one Discover request, collects Resolve responses,
  and prints a finite result.

```sh
# macOS
swift run --package-path Tools axoloty-inspect catalog --duration 10s
swift run --package-path Tools axoloty-inspect discover --core-type Identity

# Linux (container)
.devcontainer/run.sh swift run --product axoloty-inspect catalog --duration 10s
```

The inspector is built from two targets: `AxolotyInspectorCore` (zero external
dependencies, pure catalogue/filter/reducer/record logic) and
`axoloty-inspect` (CLI, depends on `Axoloty` for broker connectivity).
`AxolotyTooling`'s dependency closure is unaffected.

See [inspector.md](inspector.md) for the full reference: connection options,
catalogue filters, output modes, NDJSON schema, exit codes, and credentials.
