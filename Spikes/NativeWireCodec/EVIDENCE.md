# Issue #391 spike: complete native AxolotyWire codec

## Question

Can an Axoloty-owned implementation provide strict, borrowed decoding and safe
encoding on both host and Embedded Swift without adding a second parser backend?

## Reproduction

From the repository root, run through the pinned Swift 6.3 container:

```sh
CONTAINER_RUNTIME=podman IMAGE=axoloty-dev \
BUILD_DIR=/tmp/coaty-swift-build/axoloty/swift-6.3-linux/worktrees/391-native-wire-codec/debug \
SPM_CACHE_DIR="$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" \
.devcontainer/run.sh sh Spikes/NativeWireCodec/check.sh
```

## Prototype scope

The throwaway probe implements one-pass, strict decoding for the shared
comparison cases:

- Associate: UUIDs, escaped string, boolean, integer, missing/optional fields,
  reordered and unknown fields, duplicate rejection.
- IoValue: strict recursive validation with a borrowed raw payload slice.
- JSON strings: UTF-8 validation, JSON escapes, Unicode surrogate-pair checks.
- Numbers: JSON grammar, integer-width overflow, and integer/type distinction.
- Documents: 32-level nesting bound, truncation, delimiter, and trailing-input
  rejection.
- Encoding: escaping of quotes, backslashes, control bytes, and common escapes
  into caller-owned storage.

This is not production code and does not change AxolotyWire or host routing.
The result establishes feasibility and exposes the implementation work still
required for exhaustive event coverage and an owned async representation.

## Results

The host release probe passed every valid and malformed assertion. Across 21
samples of 50,000 Associate decodes on the development host:

| Decoder | p50 | p95 |
|---|---:|---:|
| Strict one-pass spike | 679 ns | 693 ns |
| Existing DTO + repeated `WireReader.readField` scans | 1,081 ns | 1,107 ns |

These are diagnostic same-process measurements, not a replacement for the
repository benchmark gate. They show that adding strict validation does not
inherently require a slower decoder: dispatching fields during one object pass
had about 37% lower p50 than independently rescanning the object for each DTO
property in this representative case.

The strict reader rejected all five selected malformed vectors: incomplete
literal, unbalanced array, trailing input, lone Unicode surrogate, and leading
zero. The current `IoValueWireData` path accepted all five because `readRaw`
returns a borrowed range without validating the complete value/document.

The escaping writer emitted valid JSON for an unescaped input containing a
quote, newline, and tab. The existing `WireWriter.writeStringField` copies its
input verbatim and therefore requires callers to supply already-escaped bytes.

The same core source compiled under Embedded Swift for
`riscv32-none-none-eabi`:

- Existing AxolotyWire object: 207,952 bytes.
- Strict spike object: 20,584 bytes before final linking/dead stripping.
- Host release probe executable: 705,344 bytes, including the executable
  harness and linked AxolotyWire code.

The object sizes are feasibility evidence only; they are not additive firmware
flash cost and must be replaced by the canonical linked/device measurements
before production selection.

## Verdict

Proceed with the native direction as the preferred implementation candidate.
The spike demonstrates a single strict, borrowed, one-pass parser with safe
string encoding on host and Embedded Swift, while retaining AxolotyWire's
zero-external-dependency package seam.

This does not yet prove a production cutover. Remaining work includes an
exhaustive borrowed/owned event enum, all DTO schemas, floating-point value
materialization, explicit duplicate-key policy beyond recognized schema keys,
canonical benchmark/heap measurements, dynamic host-object hydration, and the
full fixture/live compatibility suite.
