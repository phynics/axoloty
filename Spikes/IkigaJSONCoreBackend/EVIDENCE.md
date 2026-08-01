# Issue #392 spike: IkigaJSONCore backend

## Correction

The first probe confused the SwiftPM product name with its backing Swift module
name. At pinned revision `216e30b22ef3c4180e126f284a4c62d51a1c1049`,
swift-json publishes product `IkigaJSONCore`, backed by target/module
`_JSONCore`. A dependent target must select the former and import the latter.

## Reproduction

From the repository root, run through the pinned Swift 6.3 container:

```sh
CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
BUILD_DIR=/tmp/coaty-swift-build/axoloty/swift-6.3-linux/worktrees/392-ikigajsoncore-backend/debug \
SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
.devcontainer/run.sh sh Spikes/IkigaJSONCoreBackend/check.sh
```

The host probe uses the public tokenizer interface with a custom destination.
The Embedded probe compiles the same `_JSONCore` sources and consumer for
`riscv32-none-none-eabi` without `IkigaJSON`, Foundation, NIO, or Codable.

## Results

- The `_JSONCore` tokenizer and a custom `JSONTokenizerDestination` compile and
  run on host Linux.
- The same `_JSONCore` sources and consumer compile under Embedded Swift for
  `riscv32-none-none-eabi` without Foundation, NIO, or Codable.
- Embedded object sizes before final linking/dead stripping:
  `_JSONCore` 32,412 bytes; consumer probe 14,580 bytes.
- Host probe executable: 108,992 bytes.
- The tokenizer rejected incomplete literals, unbalanced arrays, and trailing
  input (the consumer checks `currentOffset`). It accepted a lone Unicode
  surrogate escape and a leading-zero number. Its tokenizer is a useful
  structural engine but is not by itself strict RFC 8259 validation.

## Packaging finding

The base `Package.swift` declares product `IkigaJSONCore`, but Swift 6.3 selects
`Package@swift-6.2.3.swift`, which omits that product while retaining the
`_JSONCore` target. The probe compiles the target sources directly to model the
small upstream manifest correction. Axoloty cannot consume the product through
SwiftPM on Swift 6.3 until upstream adds it to the version-specific manifest.

## Revised verdict

`_JSONCore` is technically viable under Embedded Swift and is materially
smaller than the native proof object, but the pinned package has a Swift 6.3
manifest defect for external consumption and its tokenizer still requires an
Axoloty strictness layer for number grammar, Unicode escapes, and likely UTF-8
validation. It remains a viable candidate, not a drop-in complete parser.
