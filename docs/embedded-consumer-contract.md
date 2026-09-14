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
