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

The checked-in ESP32-C6 firmware is also a usable external-consumer fixture.
Copy it to a directory outside the Core checkout. The copy must contain the
firmware-owned `tools` directory. The proof mounts the Core checkout and the
firmware checkout read-only, then writes only to `BUILD_DIR`.

On the four-core NixOS host, run the hardware-free proof with four build jobs:

```sh
CORE_DIR="$(git rev-parse --show-toplevel)"
FIRMWARE_DIR="$(mktemp -d /tmp/axoloty-firmware.XXXXXX)"
PROOF_BUILD_DIR=/tmp/axoloty-external-proof
cp -a "$CORE_DIR/Embedded/swift/." "$FIRMWARE_DIR/"

AXOLOTY_SOURCE_DIR="$CORE_DIR" \
EMBEDDED_PROJECT_DIR="$FIRMWARE_DIR" \
BUILD_DIR="$PROOF_BUILD_DIR" \
AXOLOTY_EXTERNAL_FIRMWARE_JOBS=4 \
make embedded-external-consumer-validate

AXOLOTY_SOURCE_DIR="$CORE_DIR" \
EMBEDDED_PROJECT_DIR="$FIRMWARE_DIR" \
BUILD_DIR="$PROOF_BUILD_DIR" \
AXOLOTY_EXTERNAL_FIRMWARE_JOBS=4 \
make embedded-external-consumer-proof
```

The proof uses the pinned `axoloty-dev` image. It does not need a board or
sudo. The preparation report, clean-room result, firmware binary, and
provenance are under
`/tmp/axoloty-external-proof/external-firmware/evidence/` and
`/tmp/axoloty-external-proof/external-firmware/axoloty-swift.bin`.
`provenance.json` records the Core SHA and dirty state, contract digest, locked
dependency and macro paths, firmware revision when available, tool versions,
artifact SHA-256, and the fact that the two source trees were disjoint.

To flash the same copy, use the NixOS non-interactive sudo wrapper on the
outer Make invocation. Do not run the firmware script with `sudo` inside the
container:

```sh
SUDO=/run/wrappers/bin/sudo \
AXOLOTY_SOURCE_DIR="$CORE_DIR" \
EMBEDDED_PROJECT_DIR="$FIRMWARE_DIR" \
EMBEDDED_DEVICE=/dev/ttyACM0 \
BUILD_DIR="$PROOF_BUILD_DIR" \
AXOLOTY_EXTERNAL_FIRMWARE_JOBS=4 \
make embedded-external-consumer-flash
```

The flash target passes `/dev/ttyACM0` only for this explicit hardware gate.
It requires the existing `flash_args` and `axoloty-swift.bin` from the
hardware-free proof, queries the chip and rejects a non-C6 device, flashes the
exact binary named by `flash_args`, and captures the
`embedded-swift-smoke-v2` JSON Lines protocol. The target reclaims root-owned
files in `BUILD_DIR` after a rootful Podman run. Check `provenance.json`,
`chip-info.txt`, `smoke-result.json`, and the binary checksum after the build
before treating the proof as a GO.

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
