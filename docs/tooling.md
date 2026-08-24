# Build and test tooling

`axoloty-tool` is Axoloty's typed command-line control plane. Its plans, process results,
hardware outcomes, and JSON manifests are defined in Swift and tested with
Swift Testing. The root Make targets forward to `axoloty-tool`; the Makefile
also retains focused recipes for specialized evidence workflows that do not
belong to the canonical verification plan.

## Repository authority

Run `axoloty-tool repository validate` (or `--format json`) to validate the
current `VERSION`, known release consumers, current-document links, AGENTS
jurisdiction, architecture invariant identifiers, and the machine-readable
architecture-exception ledger. The command is a required node of the
canonical verification graph and exits nonzero on any drift.

## Platform entry points

Linux product and ESP-IDF work is containerized:

```sh
make verify
make axoloty-tool AXOLOTY_TOOL_ARGS='wire verify'
make hardware-check
make release-fixture-bundle
```

The container image carries a stable `axoloty-tool` launcher at
`/opt/axoloty/bin/axoloty-tool`. Make targets invoke it inside the container
via `.devcontainer/run.sh`; the launcher uses `swift run --package-path Tools`
with the mounted SwiftPM cache and a dedicated `BUILD_DIR/tooling` scratch
directory. Product and test edits therefore do not invalidate the orchestration
tool build. No project binary is extracted to or baked into the image.

macOS uses its pinned native Swift toolchain:

```sh
swift run --package-path Tools axoloty-tool check
```

The root package also publishes `ax` and `axoloty-mcp`. Linux images provide
mounted-worktree launchers for all three products under `/opt/axoloty/bin`.
Use `make serve-mqtt`, `make serve-mcp`, or `make serve-dev` for thin container
entry points. Service policy remains in `AxolotyTooling`, not Make or shell.

The macOS plan runs host build, lint, tooling tests, and offline wire fixtures.
The Linux plan adds ESP32-C6 cross-compilation and linker verification. Neither
plan starts MQTT or accesses hardware.

## Command tiers

| Command | MQTT | Hardware | Purpose |
|---|:---:|:---:|---|
| `axoloty-tool check` / `axoloty-tool test offline` | no | no | Deterministic platform plan |
| `axoloty-tool wire verify` | no | no | Direct fixture and snapshot verification |
| `axoloty-tool wire capture` | local | no | Live reference-agent capture (host-side orchestration) |
| `axoloty-tool embedded build` | no | no | ESP32-C6 cross-compilation on Linux |
| `axoloty-tool embedded verify` | no | no | Build plus linker contract verification |
| `axoloty-tool measure timing` | no | no | Linux-only cold/warm build evidence |
| `axoloty-tool hardware check` | no | optional | Run when attached; otherwise structured skip |
| `axoloty-tool hardware require` | no | required | Explicit device/release gate |
| `axoloty-tool release fixture-bundle` | no | no | Bundle committed wire fixtures offline (not fresh wire evidence) |

Live CoatyJS capture, coverage, and long fuzz campaigns retain focused Make
targets while their existing evidence contracts remain in place. The former
`axoloty-tool test integration` command is retained only as a deprecation
diagnostic because its canonical broker-backed test nodes depended on removed
production APIs. Wire parsing correctness belongs to the offline tier; fresh
broker evidence belongs to the live-wire capture workflow.

The tooling test suite preserves an end-to-end development-service test as
opt-in evidence. Ordinary `test tooling` runs skip it before looking up or
starting Mosquitto and MCP. On Linux, run it explicitly with:

```sh
AXOLOTY_RUN_DEV_SERVICE_E2E=1 make axoloty-tool AXOLOTY_TOOL_ARGS='test tooling' \
	AXOLOTY_TOOL_CONTAINER_ENV_VARS=AXOLOTY_RUN_DEV_SERVICE_E2E
```

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

Hardware leases are stored below the host-mounted `AXOLOTY_DEVICE_LEASE_ROOT`
when that variable is configured. Make defaults it to the shared repository
build cache at `.../device-leases`, so concurrent containers contend on the
same canonical device path. Without the variable, the tooling manager retains
its temporary-directory default.

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

ESP-IDF C/C++ compilation uses the separately mounted
`AXOLOTY_ESP_IDF_CCACHE_DIR`. Cache entries are namespaced by the pinned IDF
revision, compiler identity, target, and build purpose, so worktrees reuse
immutable outputs without sharing their mutable build directories.

Required CI checks restore separate SwiftPM download and compiler-metadata
caches. The dependency cache key includes the lockfile, development image
definition, and reviewed image lock, with no cross-content fallback. On a
`main` run, a post-plan resolution check allows that immutable dependency cache
to be saved even when a later required check fails; a failed resolution check
leaves it unsaved. Compiler metadata and incremental build state remain
success-only, and pull requests never write trusted caches. The separate
coverage job uses an isolated instrumented build directory and does not save
mutable coverage build outputs. Development image publishing uses a GHCR-backed
BuildKit cache; ordinary source checks pull the reviewed image by digest instead
of rebuilding it.

## Fixture bundling vs fresh wire evidence

Release validation produces two distinct, deliberately separated evidence
types.

### Live wire gate

The CI `Live CoatyJS compatibility gate` ('wire capture', issue #457) enforces
live evidence for protocol-affecting changes. The gate always runs (it is a
reliable required check): when a change set touches protocol-affecting paths it
runs the containerized live capture and verifier and uploads the captures,
manifest, and verifier logs; otherwise it fast-paths to a pass. The
`live-wire-exemption` label records a dated, expiring reviewed exemption that
waives only the capture. The authoritative path list and exemption convention
live in `Tests/Support/classify-wire-change.mjs` and
`docs/wire-compatibility.md`, respectively.

### Fixture bundle (offline, deterministic)

`axoloty-tool release fixture-bundle` copies the reviewed wire captures from
the committed fixtures into `.testing/fixture-bundle`, records byte hashes,
scenario and reference-agent metadata, normalization profiles, and
repository/toolchain/image provenance, then verifies the bundle without MQTT.
The bundled manifest declares `evidence.type: fixture-bundle`,
`evidence.mode: offline`, and `evidence.live: false`, so the artifact names
itself accurately: it proves bundle integrity and byte-exact offline
reproduction of committed fixtures, not a live capture of current release
wire behavior.

`AXOLOTY_FIXTURE_BUNDLE_SOURCE` and `AXOLOTY_FIXTURE_BUNDLE_OUTPUT` override
the source and destination for a release workflow. The bundle is generated
from fixtures; stable fixtures enter source control only through normal review
and the compatibility-matrix policy. Pass a persisted or downloaded bundle to
`axoloty-tool wire verify PATH` to rerun both the Swift semantic fixture
contract and the bundle's hash/metadata checks. Fixture-bundle output
overrides must remain below `.testing/` and cannot overlap the source
captures.

### Fresh wire evidence (live capture)

Fresh evidence of current wire behavior is produced only by the live
reference-agent capture path (`axoloty-tool wire capture`, tier `wire-live`).
It runs pinned reference agents against a real MQTT broker and records raw
captures, a manifest carrying provenance, reference version, scenario, and
normalization profiles, plus Swift-side semantic verification. The fixture
bundle is never presented as this evidence.

## Release checkpoint

`make checkpoint` (or `axoloty-tool release checkpoint`) is the release
certification gate. It runs every ordinary offline check, binary-size
benchmarks, and release snapshot verification.
The canonical release-gate list (`releaseGates` in the test-tier manifest)
names every mandatory release tier — `smoke`, `unit`, `module`, `property`,
`wire-offline`, and `wire-live`. The checkpoint manifest records
a disposition for each gate:

- **executed** — a covering node ran and passed inside the checkpoint;
- **failed** — a covering node ran and at least one failed;
- **attested** — no covering node ran, but external attestation evidence was
  supplied for the gate;
- **skipped** — no covering node ran and no attestation was supplied.

The command fails if any required gate is skipped, so a release cannot be
certified with missing mandatory-tier evidence. Tiers that are not normally run
inside the checkpoint (for example the live `wire-live` capture and the
hardware smoke tier) must therefore be attested externally. Supply a path to
produced evidence for a gate as `AXOLOTY_ATTESTATION_<GATE>_PATH`, where `<GATE>`
is the uppercased tier id with hyphens replaced by underscores (for example
`AXOLOTY_ATTESTATION_WIRE_LIVE_PATH=.testing/wire/manifest.json`). The manifest
lists executed, skipped, and externally attested gates so a release reviewer
can confirm the full evidence set before certifying.

## Timing evidence

On Linux, `axoloty-tool measure timing` runs eight commands serially: cold and
warm host build, focused test build, Embedded Swift build, and ESP-IDF linker
validation. Each scenario owns a separate scratch directory; the warm run
reuses the cold directory. Use `--scratch-root PATH` to select the root and
`--keep-scratch` to retain the directories for inspection:

```sh
axoloty-tool measure timing \
  --filter AxolotyCommandDispatcherTests \
  --scratch-root .testing/timing --keep-scratch
```

Standard output is one sorted-key JSON report. Each measurement records its
command plan, monotonic duration, child exit status, bounded failure diagnostic,
scratch reuse, toolchain identity, parsed build-step count, and cache counters.
Metrics that are not present in command output are marked `unavailable`; the
runner never estimates them. The command uses only build and linker validation
plans and never probes devices, acquires leases, starts a broker, or performs
network I/O. macOS returns a structured unsupported-platform result instead of
launching a measurement.

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

The inspector uses `AxolotyInspectorCore` (zero external dependencies, pure
catalogue/filter/reducer/record logic), `AxolotyInspectorRuntime` (the
runtime adapter), and `axoloty-inspect` (the CLI, using `AxolotyRuntime` and
`MQTTBinding` for broker connectivity).
`AxolotyTooling`'s dependency closure is unaffected.

See [inspector.md](inspector.md) for the full reference: connection options,
catalogue filters, output modes, JSON-array/NDJSON schema, exit codes, and credentials.
