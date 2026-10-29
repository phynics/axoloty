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

## Wire profiles

The `wireProfiles` array declares the wire profiles this contract can serve.
Each entry names a `protocolName`/`protocolVersion` pair, its `encoding`, whether
it needs the `_JSONCore` parser (`requiresJSONCore`), and whether it is the
`default` profile.

- `coaty3JSON` is `coaty/3` JSON, requires `_JSONCore`, and is the default. It
  keeps the sealed `coaty/3` wire bytes unchanged.
- `axoloty1CBOR` is `axoloty/1` CBOR and does not require `_JSONCore`.

`axoloty1CBOR` is mandatory. `coaty3JSON` is required only when a declared
profile needs the JSON parser, so the two profiles are not symmetric: every
contract names the CBOR profile, and a JSON-only contract is not accepted.
Exactly one declared profile is the default; `coaty3JSON` is the default when it
is declared, otherwise `axoloty1CBOR`.

`jsonCore` is present exactly when a declared profile sets
`requiresJSONCore: true`. A contract that declares only CBOR profiles omits
`jsonCore`, so a CBOR-only consumer needs no JSON parser. The
`Packages/AxolotyWire` package gates `IkigaJSONCore` behind the default-enabled
`CoatyJSON` SwiftPM trait; build the package with `--disable-default-traits` to
link a CBOR-only `AxolotyWire`.

A CBOR-only `AxolotyWire` build drops the JSON-only borrowed entry points:
`BorrowedMessage.reader()` and `BorrowedWireEvent.init(message:)` are absent.
Decode through `WireCodec.reader(bytes:length:)` and
`BorrowedWireEvent.init(eventType:from:)` instead. Calling
`WireCodec.reader(bytes:length:)` or `WireCodec.isValidBareValue(_:)` for the
`.coaty3JSON` profile traps when `_JSONCore` is unavailable; a CBOR-only
consumer selects `.axoloty1CBOR`.

The preparation command accepts `--profile` to select a declared profile.
Without it, the report covers every declared profile. When all selected
profiles omit `requiresJSONCore: true`, the report does not require an
`_JSONCore` revision entry and omits `jsonCore` from the
schema-version-1 report. A
selection that includes a JSON profile emits `jsonCore`. The report schema
remains version 1; a CBOR-only selection simply omits `jsonCore`.

`AxolotyObjectModel` exposes `BoundedCBORObject<byteCapacity, fieldCapacity>`
for bounded materialization of an `axoloty/1` object map. It validates and owns
the complete deterministic CBOR bytes, enforces the caller's inline byte and
field capacities, and lends exact encoded field values only during a
synchronous callback. Unknown fields and CBOR-only values such as byte strings
remain in their original CBOR representation; this API does not convert them
to JSON. Existing `BoundedDynamicObject` and `BoundedObject` remain the JSON
object and schema APIs.

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

The committed standalone lock selects `swift-json`. When the contract declares
a JSON profile, after the build verify that its checkout revision equals
`jsonCore.revision`. Its portable source is at:

```text
$CONSUMER_CORE_TOOLS_SCRATCH/checkouts/swift-json/Sources/_JSONCore
```

Building `AxolotyStaticRuntime` links the macro executable as a build
prerequisite. Building only the macro target compiles its objects but does not
link the executable with SwiftPM 6.4. Locate the output directory with the same
package and scratch arguments plus `swift build --show-bin-path`.

The executable name depends on the build system. SwiftPM's native build system
emits `staticRuntimeMacro.executable`, which ends in `-tool`. Swift Build, the
SwiftPM default from 6.4 across supported platforms, emits the bare target name
without that suffix. A consumer accepts either, preferring the contract
spelling; the preparation report always carries the resolved absolute path, so
a consumer that reads the report needs no name handling of its own. Load it
with:

```text
-load-plugin-executable <absolute-executable-path>#AxolotyStaticRuntimeMacrosImplementation
```

The macro executable, and the `_JSONCore` source when the contract requires
JSON, must remain inside `CONSUMER_CORE_TOOLS_SCRATCH`.

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

## Compile the Zenoh Core module

`AxolotyZenohCore` is a separate portable module. It is not a sixth entry in
`portablePackages`, which remains the same five-module sequence above. The
preparation report exposes it separately as `zenohCore` with the absolute
`sourceDir`, module name, façade module name, façade header path, header SHA-256,
and a generated module-map path.

The generated `CAxolotyZenoh/module.modulemap` lives in caller-owned scratch and
imports only the reported `axoloty_zenoh.h` header. Use it when compiling the
reported Swift source directory, after `AxolotyWire` is available. The header
digest identifies the exact C declarations used by the Swift module. The Core
commit and dirty flag continue to identify the selected checkout.

Firmware supplies the `axoloty_zenoh_*` implementations. The contract does not
export or link the host `CZenohC` system library, `zenoh-c`, the host C
implementation, or the `AxolotyZenoh` runtime adapter. The Core-side
`zenoh-core-embedded` gate compiles this module for RISC-V Embedded Swift and
checks that only façade and supported runtime symbols remain unresolved.

## Supported preparation hosts

Linux through the pinned container is the reference host and the one required
CI uses. macOS preparation is [best effort](./SUPPORT_MATRIX.md#platforms),
with no macOS CI. The portable packages declare a 26.0 Apple platform floor,
and preparation accepts the Swift Build macro executable name. The firmware
build itself needs ESP-IDF in the container.

## Supported preparation command

An external firmware checkout obtains Core paths and build-time tools from the
supported command. Set `AXOLOTY_SOURCE_DIR` to an existing, clean, canonical
Axoloty checkout and provide absolute paths owned by the caller:

```sh
axoloty-tool embedded consumer prepare \
  --scratch /tmp/axoloty-consumer-tools \
  --output /tmp/axoloty-consumer-preparation.json
```

Pass `--profile axoloty1CBOR` to prepare a CBOR-only consumer from a contract
that declares both profiles. The report's `selectedWireProfiles` records the
selection. Preparation omits `jsonCore` for that selection. Preparing the
static-runtime target also builds its macro executable prerequisite. The
CBOR-only Core compile and link gate proves that the selected modules do not
import or link `_JSONCore`. Without `--profile`, preparation selects every
profile in the contract and includes `_JSONCore` when any selected profile
requires it.

The command validates the contract before invoking SwiftPM, builds
`AxolotyStaticRuntime` with the committed lock and
`--disable-automatic-resolution`, and emits the same versioned JSON report
that it writes to `--output`. It does not inspect `Tests/Support`, firmware
files, ESP-IDF, or hardware. Scratch and output paths must be outside Core.

The report has schema version 1 and contains the Core commit and dirty state,
the contract SHA-256, Swift 6.4 compiler flags, the five portable source
directories in dependency order, the locked `_JSONCore` revision and source
when a declared profile requires the JSON parser, the static-runtime macro
executable and scratch directory, and the separate `zenohCore` source and
façade metadata. A CBOR-only contract omits `jsonCore`; every other field is
unchanged. The `zenohCore` object contains:

- `module` and `sourceDir` for `AxolotyZenohCore`;
- `facadeModule` and `facadeHeader` for the `CAxolotyZenoh` C module;
- `facadeHeaderSHA256` for the exact header bytes; and
- `moduleMap`, a generated module map inside caller-owned scratch.

Consumers must treat paths as absolute and reject reports with an unknown
schema or a path outside the declared Core or scratch roots. Existing consumers
may continue to use the five `portablePackages` entries and ignore `zenohCore`.

## External firmware proof

The ESP32-C6 build, flash, and device-qualification proof that consumes this
contract lives in
[`phynics/axoloty-embedded`](https://github.com/phynics/axoloty-embedded).
That repository selects a Core checkout with `AXOLOTY_SOURCE_DIR`, runs
`axoloty-tool embedded consumer prepare`, and owns its firmware, toolchain,
device, and evidence artifacts. This repository keeps the contract, the
preparation command, and the hardware-free portability gate below.

## Verify Core portability

Run the required hardware-free consumer gate through the repository entry
point:

```sh
make check-embedded-core-consumer
```

The gate compiles `_JSONCore` and all five portable packages for the repository's
RISC-V Embedded Swift test target when the contract declares a JSON profile. It
then compiles a real `@StaticIoActor` consumer with the resolved macro
executable and performs a relocatable link of the resulting objects. A second
leg compiles and links a CBOR-only consumer that imports no `_JSONCore` and
asserts that the linked objects carry no JSON symbols. It also compiles and
links the full five-module portable graph plus a static-runtime consumer with
no `_JSONCore`, then checks that link for JSON symbols. Only the CBOR wire
probe runs on the host after Embedded Swift compilation. The Core consumer is
compiled and linked but not executed, so that leg proves the graph builds and
links without `_JSONCore`, not runtime behavior; the host `StaticRuntimeTests`
and `BoundedCBORObjectTests` cover behavior. A CBOR-only contract therefore
omits `_JSONCore` preparation and still compiles the complete selected
profile. The gate reads
Core sources
and caller-owned scratch
storage only. It does not read the firmware project, invoke ESP-IDF, use a
broker, or probe hardware. Portable targets also enable the Swift 6.4
`EmbeddedRestrictions` warning group as an advisory host-build signal; this
RISC-V consumer build remains the enforcing gate for language and standard
library compatibility.

The target triple and linker are test-gate implementation details. They do not
extend the downstream contract described by
`docs/embedded-consumer-contract.json`.

## Validate the repository cutover

The required `repository-cutover-boundary` gate verifies this contract from the
Core side: it rejects contract paths that leave the checkout or enter private
Core layout, keeps `AXOLOTY_SOURCE_DIR` the only documented local override, and
pins the required plan against firmware and hardware coupling. With
`AXOLOTY_EMBEDDED_COMPARE_DIR` it audits a firmware checkout, its lock, and its
recorded evidence against this Core checkout. See
[embedded-cutover-validation.md](./embedded-cutover-validation.md).
