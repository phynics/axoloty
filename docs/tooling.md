# Build and test tooling

`ax` is Axoloty's typed command-line control plane. Its plans, process results,
hardware outcomes, and JSON manifests are defined in Swift and tested with
Swift Testing. The root Makefile remains a lightweight command index and Linux
container bootstrap rather than a second orchestration implementation.

## Platform entry points

Linux product and ESP-IDF work is containerized:

```sh
make check
make ax AX_ARGS='wire verify'
make hardware-check
```

macOS uses its pinned native Swift toolchain:

```sh
swift package resolve --cache-path .swiftpm-cache
swift run --cache-path .swiftpm-cache --disable-automatic-resolution ax check
```

The macOS plan runs host build, lint, tooling tests, and offline wire fixtures.
The Linux plan adds ESP32-C6 cross-compilation and linker verification. Neither
plan starts MQTT or accesses hardware.

## Command tiers

| Command | MQTT | Hardware | Purpose |
|---|:---:|:---:|---|
| `ax check` / `ax test offline` | no | no | Deterministic platform plan |
| `ax wire verify` | no | no | Direct fixture and snapshot verification |
| `ax embedded build` | no | no | ESP32-C6 cross-compilation on Linux |
| `ax embedded verify` | no | no | Build plus linker contract verification |
| `ax hardware check` | no | optional | Run when attached; otherwise structured skip |
| `ax hardware require` | no | required | Explicit device/release gate |

Broker-backed transport, live CoatyJS capture, coverage, and long fuzz campaigns
retain focused Make targets while their existing evidence contracts remain in
place. Wire parsing correctness belongs to the offline tier; MQTT tests only
transport behavior.

## Structured output

`ax` writes its result JSON to standard output and child/bootstrap diagnostics
to standard error. A check result records the stable node name, status, exit
code, and captured streams. Failed prerequisites cause dependent nodes to be
reported as skipped while independent nodes continue, so a single invocation
describes the complete planned pass.

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

## Adding tooling

Add orchestration behavior to the `AxolotyTooling` target with injected process,
filesystem, environment, clock, or platform boundaries as applicable. Add
Swift Testing coverage and expose the behavior through `ax`; add a short Make
alias only when Linux contributors need a documented container entry point.
Do not add a new Bash or Python front controller.
