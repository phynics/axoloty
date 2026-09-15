# Embedded consumer contract

`docs/embedded-consumer-contract.json` is the machine-readable contract for
firmware that compiles Axoloty portable source outside this repository. The
contract describes Core source and dependency identities. It does not define a
firmware build system, a board, a transport, or a target triple.

## Select the Core checkout

Set `AXOLOTY_SOURCE_DIR` to the canonical absolute path of the selected Axoloty
Git checkout. This variable is the only public local-development override.
Record the checkout's 40-character commit SHA and dirty state in downstream
build evidence.

The `repository` object identifies the expected repository and the revision
format. A downstream lock selects the exact Axoloty revision. The contract does
not contain its own commit because a file cannot name the commit that contains
it.

## Validate the contract

Run the Core-owned validator from the selected checkout:

```sh
swift run \
  --package-path "$AXOLOTY_SOURCE_DIR/Tools" \
  --scratch-path "$CONSUMER_TOOLING_SCRATCH" \
  axoloty-tool repository validate \
  --embedded-consumer-contract \
  --format json
```

`CONSUMER_TOOLING_SCRATCH` must name storage owned by the downstream caller.
The command reads the contract, the five standalone package manifests, the root
manifest, and the committed SwiftPM locks. It does not resolve dependencies or
use the network.

The command exits with status 1 when the contract and the selected checkout
disagree. Its JSON report contains stable rule identifiers, repository-relative
paths, and actionable messages.

## Resolve `_JSONCore` and the macro executable

Use the standalone `Packages/AxolotyStaticRuntime` package and caller-owned
scratch storage:

```sh
swift build \
  --package-path "$AXOLOTY_SOURCE_DIR/Packages/AxolotyStaticRuntime" \
  --scratch-path "$CONSUMER_CORE_TOOLS_SCRATCH" \
  --disable-automatic-resolution \
  --configuration debug \
  --target AxolotyStaticRuntime
```

The committed standalone lock selects `swift-json`. After the build, verify
that its checkout revision equals `jsonCore.revision`. Its portable source is
at:

```text
$CONSUMER_CORE_TOOLS_SCRATCH/checkouts/swift-json/Sources/_JSONCore
```

Building `AxolotyStaticRuntime` links the macro executable as a build
prerequisite. Building only the macro target compiles its objects but does not
link the executable with SwiftPM 6.3. Locate the output directory with the same
package and scratch arguments plus `swift build --show-bin-path`. The executable
name is `staticRuntimeMacro.executable`. Load it with:

```text
-load-plugin-executable <absolute-executable-path>#AxolotyStaticRuntimeMacrosImplementation
```

Both the `_JSONCore` source and the macro executable must remain inside
`CONSUMER_CORE_TOOLS_SCRATCH`.

## Compile the portable modules

Compile the five entries in `portablePackages` with the ordered arguments in
`swift.requiredCompilerFlags`. Resolve every `packagePath` and `sourcePath`
relative to `AXOLOTY_SOURCE_DIR`, and reject paths that escape that checkout.

The following paths are private and unsupported:

- Axoloty's root `.build` directory.
- Parent-directory checkout discovery.
- Files under Axoloty `Tests/`.
- ESP-IDF component names and build directories.

Consumers may add platform flags, a target triple, and SDK-specific integration.
Those settings do not change the Core contract.

## Supported preparation command

An external firmware checkout obtains Core paths and build-time tools from the
supported command. Set `AXOLOTY_SOURCE_DIR` to an existing, clean, canonical
Axoloty checkout and provide absolute paths owned by the caller:

```sh
axoloty-tool embedded consumer prepare \
  --scratch /tmp/axoloty-consumer-tools \
  --output /tmp/axoloty-consumer-preparation.json
```

The command validates the contract before invoking SwiftPM, builds
`AxolotyStaticRuntime` with the committed lock and
`--disable-automatic-resolution`, and emits the same versioned JSON report
that it writes to `--output`. It does not inspect `Tests/Support`, firmware
files, ESP-IDF, or hardware. Scratch and output paths must be outside Core.

The report has schema version 1 and contains the Core commit and dirty state,
the contract SHA-256, Swift 6.3 compiler flags, the five portable source
directories in dependency order, the locked `_JSONCore` revision and source,
and the static-runtime macro executable and scratch directory. Consumers must
treat paths as absolute and reject reports with an unknown schema or a path
outside the declared Core or scratch roots.

## Run the external firmware proof

The checked-in ESP32-C6 firmware is extracted by the build target into an
unrelated sibling directory. The target creates this run layout and mounts the
two source trees read-only:

```text
/tmp/axoloty-go-proof/<run-id>/
  core/             # sparse Axoloty checkout (no Tests/ or Embedded/)
  firmware/         # Embedded/swift archive from the same commit
  build/            # ESP-IDF output, including flash_args
  core-tools/       # caller-owned SwiftPM preparation scratch
  tooling/          # proof tooling scratch
  working-evidence/ # intermediate evidence before durable copy
```

After the remediation PRs merge, create a fresh, detached `origin/main` driver
checkout. Keep this driver checkout separate from both the Core and firmware
trees that the proof creates. While validating this branch before merge, use
the proof branch's final commit in place of `origin/main`.

```sh
export AXOLOTY_PROOF_DRIVER=/tmp/axoloty-go-driver
git clone https://github.com/phynics/axoloty.git "$AXOLOTY_PROOF_DRIVER"
cd "$AXOLOTY_PROOF_DRIVER"
git switch --detach origin/main
test -z "$(git status --porcelain)"
```

Prepare the pinned image and choose one run identifier. The build is rootless
and may take up to two hours on this four-core machine; cold Swift macro
preparation can spend about 15 minutes compiling before ESP-IDF starts. Do not
cancel while compiler or heartbeat output advances.

```sh
export AXOLOTY_PROOF_RUN_ID="go-$(date -u +%Y%m%dT%H%M%SZ)"
make image
make embedded-toolchain-doctor
make embedded-consumer-proof-build \
  AXOLOTY_PROOF_RUN_ID="$AXOLOTY_PROOF_RUN_ID"
```

Connect an ESP32-C6, identify its serial device, and refresh sudo credentials.
Sudo is used only by the outer flash target to run the rootful device
container; it is not used by the build or inside the firmware scripts.

```sh
ls -l /dev/ttyACM* /dev/ttyUSB*
sudo -v
sudo -n true
SUDO=/run/wrappers/bin/sudo \
EMBEDDED_DEVICE=/dev/ttyACM0 \
make embedded-consumer-proof-flash \
  AXOLOTY_PROOF_RUN_ID="$AXOLOTY_PROOF_RUN_ID"
make embedded-consumer-proof-validate \
  AXOLOTY_PROOF_RUN_ID="$AXOLOTY_PROOF_RUN_ID"
```

Override `EMBEDDED_DEVICE` when enumeration differs. The flash stage never
rebuilds: it requires the existing `flash_args` and `axoloty-swift.bin`,
queries and validates the ESP32-C6 identity, flashes that exact artifact,
captures bounded serial output, and validates the checksummed
`embedded-swift-smoke-v2` JSONL boot, all 22 cases, summary, and completion.
Any reboot, fatal output, malformed record, checksum failure, missing case, or
timeout leaves the proof failed. Durable evidence is copied to
`.testing/embedded/consumer-proof/<run-id>/`:

```text
build.log
preparation.json
clean-room.json
consumer-preparation.stdout
build-provenance.json
device-manifest.json
device-info-raw.txt
flash.log
swift-smoke-log.txt
swift-smoke-result.json
axoloty-swift.bin
go-proof.json
```

The final validator prints `EMBEDDED CONSUMER GO PROOF PASSED` only when
`go-proof.json` reports `result: "passed"` and cross-checks the clean Core SHA,
contract hash, artifact SHA-256, ESP32-C6 identity, and smoke result.

`AxolotySensorThingsModel` remains a portable package for host applications,
but it is intentionally absent from this standalone contract: the offline
embedded fixture has no SensorThings dependency and the five-package list is
the complete production protocol/runtime closure for the ESP32-C6 consumer.

## Verify Core portability

Run the required hardware-free consumer gate through the repository entry
point:

```sh
make check-embedded-core-consumer
```

The gate compiles `_JSONCore` and all five portable packages for the repository's
RISC-V Embedded Swift test target. It then compiles a real `@StaticIoActor`
consumer with the resolved macro executable and performs a relocatable link of
the resulting objects. The gate reads Core sources and caller-owned scratch
storage only. It does not read the firmware project, invoke ESP-IDF, use a
broker, or probe hardware.

The target triple and linker are test-gate implementation details. They do not
extend the downstream contract described by
`docs/embedded-consumer-contract.json`.
