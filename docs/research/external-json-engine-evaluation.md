<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# External JSON engine evaluation for AxolotyWire

Status: research and spike plan for [#390](https://github.com/phynics/axoloty/issues/390), 2026-08-01.

## Executive summary

Axoloty should not adopt a production-owned JSON grammar parser until maintained
external engines have been evaluated on the real host and ESP32-C6 toolchains.
The earlier choice between the current native scanner and a presumed missing
`IkigaJSONCore` module was incomplete and contained a product/module error.

The evidence supports four implementation families:

1. swift-json `_JSONCore`, after correcting its Swift 6.3 package manifest;
2. an embedded C engine behind an Axoloty-owned token/range ABI;
3. a Rust `no_std` engine behind the same ABI;
4. the native Swift parser as the control and fallback.

The first measured comparison should include `_JSONCore`, `mjson`, and
`yyjson`, with the native spike as baseline. A Rust toolchain/ABI feasibility
gate should run separately before investing in a full Rust adapter. C++ DOM
libraries and minimal tokenizers remain documented alternatives but are not the
first shortlist.

No production engine is selected by this paper.

## Axoloty requirements

An engine used by AxolotyWire must satisfy all of these constraints:

- Parse the same bytes on Linux/Apple hosts and ESP32-C6; a host/embedded split
  would preserve the semantic duplication this work is intended to remove.
- Accept a borrowed `const uint8_t *` plus explicit length and retain nothing
  after synchronous return.
- Preserve raw value ranges for opaque Coaty object, filter, private-data, and
  IO payload fields.
- Reject malformed/truncated input deterministically, with bounded depth and a
  byte offset/reason suitable for `WireDecodeError`.
- Correctly handle UTF-8, JSON escapes and surrogate pairs, integer bounds,
  floating-point grammar, null/missing distinctions, duplicate keys, and
  trailing input.
- Encode into caller-owned fixed storage with explicit overflow; no unbounded
  output allocation.
- Fit the current 128-byte topic and 512-byte payload limits, zero-allocation
  steady-state goal, 1 MiB flash-image budget, and device stack/throughput gates
  in [`performance-budgets.md`](../performance-budgets.md).
- Use a compatible permissive license and pinned, reproducible source.

The engine should own JSON grammar. AxolotyWire should still own Coaty topics,
event schemas, required/optional fields, borrowed and owned event values, and
wire error mapping. Dynamic `CoatyObject` registration remains a host adapter.

## Important correction: swift-json core exists

At pinned swift-json revision
[`216e30b`](https://github.com/orlandos-nl/swift-json/tree/216e30b22ef3c4180e126f284a4c62d51a1c1049),
the base manifest declares product `IkigaJSONCore`, backed by target/module
`_JSONCore` ([manifest](https://github.com/orlandos-nl/swift-json/blob/216e30b22ef3c4180e126f284a4c62d51a1c1049/Package.swift)).
Swift imports the target module as `_JSONCore`; it does not import the product
name.

Swift 6.3 instead selects upstream
[`Package@swift-6.2.3.swift`](https://github.com/orlandos-nl/swift-json/blob/216e30b22ef3c4180e126f284a4c62d51a1c1049/Package@swift-6.2.3.swift),
which retains `_JSONCore` but omits the `IkigaJSONCore` product. This is a
manifest packaging defect for Axoloty's toolchain, not proof that the code is
incompatible with Embedded Swift.

The corrected #392 spike compiled `_JSONCore` and a custom tokenizer
destination on host and for `riscv32-none-none-eabi`:

- `_JSONCore` Embedded object: 32,412 bytes before final link/dead stripping;
- consumer probe object: 14,580 bytes;
- host probe executable: 108,992 bytes.

The public tokenizer accepts borrowed `UnsafeBufferPointer<UInt8>` input and
reports token byte positions through `JSONTokenizerDestination`
([tokenizer](https://github.com/orlandos-nl/swift-json/blob/216e30b22ef3c4180e126f284a4c62d51a1c1049/Sources/_JSONCore/Parser/JSONTokenizer.swift),
[destination](https://github.com/orlandos-nl/swift-json/blob/216e30b22ef3c4180e126f284a4c62d51a1c1049/Sources/_JSONCore/Parser/JSONTokenizerDestination.swift)).

It is not a complete strict engine as currently implemented. The corrected
probe rejected incomplete literals, unbalanced arrays, and trailing input, but
accepted a lone Unicode surrogate and a leading-zero number. Source inspection
shows number scanning consumes a broad set of number-like bytes without full
RFC grammar validation, while string scanning locates the closing quote but
does not itself validate all escapes/UTF-8
([parsing source](https://github.com/orlandos-nl/swift-json/blob/216e30b22ef3c4180e126f284a4c62d51a1c1049/Sources/_JSONCore/Parser/JSONParser%2BParsing.swift)).

Therefore `_JSONCore` reduces structural-parser ownership but still needs
upstream fixes or an Axoloty strictness layer. It also provides tokenization,
not a complete Axoloty writer.

## Candidate matrix

| Candidate | Language/model | Allocation/raw ranges | Correctness ownership | Integration cost | Initial disposition |
|---|---|---|---|---|---|
| swift-json `_JSONCore` | Swift tokenizer/SAX destination | Borrowed input and byte positions; no Foundation/NIO in core | Structural parsing upstream; strict number/string validation still unresolved | Lowest language/ABI cost; Swift 6.3 manifest must be fixed upstream or pinned fork | **Shortlist** |
| Cesanta `mjson` | C state machine/SAX + emitter | README states no allocation and no recursion; `mjson_next` returns offsets/lengths; fixed-buffer printer | Upstream parser, but README makes no strong RFC 8259/UTF-8 claim; must run malformed/fuzz corpus | Small C component and narrow wrapper; variadic emitter must stay behind C wrapper | **Shortlist** |
| `yyjson` | ANSI C immutable/mutable DOM | Custom allocator and in-situ mode; DOM is allocated; raw-range preservation needs proof | Claims strict RFC 8259, UTF-8 validation, accurate integer/double parsing; fuzz/test evidence upstream | One `.c`/`.h`; fixed arena and C wrapper required | **Shortlist** |
| Native Axoloty parser | Swift schema-driven cursor | Borrowed, fixed-buffer, no dependency | Entire grammar, security, fuzzing, and maintenance owned by Axoloty | Lowest build complexity, highest long-term parser burden | **Control/fallback** |
| Rust `serde-json-core` | Rust `no_std`, Serde typed decode/encode | No allocation; zero-copy `str` where no unescaping is needed; caller slice output | Mature Rust/Serde implementation | New Rust toolchain/staticlib/C ABI; typed use duplicates Coaty schemas in Rust | **Toolchain spike only** |
| Rust `serde_json` with `alloc` | Rust DOM/typed | Requires allocator without `std` | Strong upstream implementation | Rust runtime plus allocator; no advantage over `serde-json-core` for 512-byte embedded messages | Defer |
| `jsmn` | C token array | No allocation, token offsets, incremental single pass | README explicitly treats exhaustive correctness checking as optional; primitive types are undifferentiated; no writer | Tiny wrapper, but Axoloty retains too much validation/writer ownership | Reject from first round |
| ESP-style `cJSON` | ANSI C allocated DOM | Allocates a tree; parsed raw ranges are not its model | Upstream documents invalid UTF-8 propagation, no `\u0000`, permissive trailing input unless opted out | Easy C bridge, but conflicts with raw/zero-allocation requirements | Reject from first round |
| ArduinoJson 7 | Header-only C++ DOM | Custom allocators; document model; serialization to buffer/stream | Extensively tested and OSS-Fuzzed, but supports permissive syntax such as single-quoted strings | Adds C++ build/ABI wrapper; raw-range preservation is not its natural interface | Secondary C++ candidate |
| RapidJSON | Header-only C++ SAX/DOM/writer | SAX available; custom allocator/DOM options | Complete Unicode-aware parser/writer claimed upstream | Larger C++ interface and maintenance surface than C shortlist; old stable release line | Secondary C++ candidate |

## Candidate details

### C: mjson

[`mjson`](https://github.com/cesanta/mjson) is MIT-licensed, roughly 1,000
lines, dependency-free, non-recursive, and allocation-free while parsing. Its
low-level SAX interface and `mjson_next` return pointers or offsets into the
original input. Its emitter can target a fixed buffer or caller callback
([README](https://github.com/cesanta/mjson/blob/master/README.md),
[license](https://github.com/cesanta/mjson/blob/master/LICENSE)).

This is the closest C match to Axoloty's borrowed model. Risks are parser
strictness and integer semantics: high-level number extraction uses `double`,
and the project does not claim the same strict RFC/UTF-8 guarantees as yyjson.
Axoloty should consume token ranges and parse bounded integers deliberately,
not route IDs/rates through `double`.

### C: yyjson

[`yyjson`](https://github.com/ibireme/yyjson) is MIT-licensed ANSI C with a
single source/header integration. It claims strict RFC 8259 behavior, UTF-8
validation, accurate signed/unsigned 64-bit and double handling, custom
allocators, bounded-length input, and read/write support
([README](https://github.com/ibireme/yyjson/blob/master/README.md),
[license](https://github.com/ibireme/yyjson/blob/master/LICENSE)).

Its principal mismatch is representation: parsed arrays and objects form an
immutable DOM. A 512-byte payload may make a caller-provided fixed arena
acceptable, but that must be measured at the maximum corpus case. In-situ mode
modifies input and is incompatible with immutable borrowed transport bytes
unless Axoloty first copies the payload. Non-in-situ parsing and preservation
of original raw subranges require a concrete adapter proof.

### C: jsmn and cJSON

[`jsmn`](https://github.com/zserge/jsmn) is MIT-licensed C89, approximately 200
lines, dependency-free, allocation-free, and returns token offsets. However,
its own design statement says checking every JSON packet for correctness is
often overkill; primitives are a single token category and it has no emitter
([README](https://github.com/zserge/jsmn/blob/master/README.md)). Choosing it
would largely transfer parser maintenance from one small parser to another.

[`cJSON`](https://github.com/DaveGamble/cJSON) is MIT-licensed ANSI C and easy
to integrate, but parsing allocates a linked tree. Its documentation states
that invalid UTF-8 is usually propagated, `\u0000` is unsupported, duplicate
keys are allowed, and trailing input is accepted unless stricter options are
used. Preallocated printing exists, but raw input ranges are not the parse
model ([README](https://github.com/DaveGamble/cJSON/blob/master/README.md)).

### C++: ArduinoJson and RapidJSON

[`ArduinoJson`](https://github.com/bblanchon/ArduinoJson) is an active,
MIT-licensed, header-only C++11+ library targeting ESP32 and other embedded
boards. It supports custom allocators, custom readers/writers, buffer output,
near-complete unit coverage, and OSS-Fuzz
([README](https://github.com/bblanchon/ArduinoJson/blob/7.x/README.md),
[license](https://github.com/bblanchon/ArduinoJson/blob/7.x/LICENSE.txt)).
It is credible when an application wants an embedded DOM. Axoloty instead wants
borrowed raw ranges and currently has no C++ integration, so it ranks behind
the C shortlist.

[`RapidJSON`](https://github.com/Tencent/rapidjson) provides self-contained
C++ SAX and DOM parsers plus writers, Unicode validation/transcoding, surrogate
handling, and custom allocation. It is MIT-licensed according to its project
README. Its breadth and C++ wrapper surface are unnecessary unless smaller C
and Swift candidates fail
([README](https://github.com/Tencent/rapidjson/blob/master/readme.md)).

### Rust: serde-json-core

[`serde-json-core`](https://github.com/rust-embedded-community/serde-json-core)
is a maintained `no_std` crate, MIT OR Apache-2.0. Its current manifest requires
stable Rust 1.87 and depends on Serde plus `ryu`, with optional `heapless`
([manifest](https://github.com/rust-embedded-community/serde-json-core/blob/master/Cargo.toml),
[README](https://github.com/rust-embedded-community/serde-json-core/blob/master/README.md)).
The crate documents allocation-free typed serialization/deserialization,
direct parsing into requested integer widths, zero-copy strings when no
de-escaping is required, and caller-provided output slices
([crate source](https://github.com/rust-embedded-community/serde-json-core/blob/master/src/lib.rs)).

The technical parser is attractive; the module seam is not. Using Serde's
strength requires mirroring every Coaty wire schema as Rust structs, while a
generic token C ABI discards much of Serde's value. Axoloty's image currently
contains no Rust toolchain, Cargo package, Rust runtime, or Rust/Swift ABI.
Rust should receive a cheap static-library/toolchain gate, not a full adapter,
unless there is a broader strategic reason to introduce Rust.

Standard `serde_json` also supports `no_std` with an allocator, but explicitly
directs allocator-free programs to `serde-json-core`
([README](https://github.com/serde-rs/json/blob/master/README.md#no-std-support)).

## Proposed C/Rust ABI

Do not expose a third-party DOM, callbacks into Swift, variadic functions, or
library-specific handles. A C or Rust implementation should sit behind an
Axoloty-owned ABI equivalent to:

```c
typedef struct {
    uint16_t start;
    uint16_t end;
    uint16_t parent;
    uint8_t kind;
    uint8_t flags;
} ax_json_token;

typedef struct {
    uint16_t offset;
    uint8_t reason;
} ax_json_error;

int ax_json_tokenize(
    const uint8_t *input,
    uint16_t length,
    ax_json_token *tokens,
    uint16_t token_capacity,
    ax_json_error *error
);
```

Properties of this seam:

- input remains caller-owned and immutable;
- token storage is caller-owned and bounded;
- tokens contain offsets, never retained pointers;
- no callback crosses C/Rust/Swift per token;
- overflow is a normal structured result;
- the same static library and semantics run on host and ESP32-C6;
- Swift builds Coaty-specific DTOs and raw `ByteSlice` values from ranges.

At 512 input bytes, worst-case token count and token-record size must be
measured before selecting this design. If the scratch table is too large, a
stateful cursor ABI is preferable to heap allocation. Encoding should use a
separate fixed-output ABI; C variadics must remain hidden inside the wrapper.

## Evaluation plan

### Gate 0: upstream and toolchain viability

- Submit or carry a minimal swift-json manifest patch that exposes
  `IkigaJSONCore` under Swift 6.3; do not fork parser implementation.
- Compile pinned `mjson` and `yyjson` as host and ESP-IDF components.
- Add Rust 1.87 and the ESP32-C6-compatible RISC-V target only in an isolated
  spike image; produce and link one `no_std` C-ABI static function.
- Stop any candidate that cannot be pinned, licensed, cross-compiled, and
  linked reproducibly.

### Gate 1: identical semantics

Run every candidate through the same vectors:

- all 13 families and three size classes in `Benchmarks/Corpus`;
- CoatyJS and legacy compatibility fixtures;
- truncation at every byte and deterministic corruption;
- UTF-8, escapes, surrogate pairs, control characters, number grammar and
  integer limits;
- null/missing, unknown/reordered/duplicate fields, depth limits, and trailing
  bytes;
- raw-range equality for every opaque wire field;
- fixed-buffer encoding and semantic round trips.

Do not patch semantic failures in the benchmark adapter. Record whether a fix
belongs upstream or would become permanent Axoloty parser maintenance.

### Gate 2: resources and performance

Measure using repository harness conventions:

- release p50/p95 and allocation count on host;
- stripped consumer size and dynamic dependency closure;
- linked ESP32-C6 flash sections, peak heap, stack high-water, and sustained
  100 msg/s processing;
- maximum token/arena scratch size for a 512-byte payload;
- FFI overhead independently from parsing cost.

### Gate 3: maintainability

For finalists, record:

- upstream release/activity and fuzzing posture;
- amount of Axoloty-owned grammar/Unicode/number code;
- wrapper lines and unsafe operations;
- upgrade procedure and patch delta;
- whether host and embedded truly execute the same engine.

## Recommended shortlist

Advance these candidates to measured spikes:

1. **swift-json `_JSONCore` with corrected manifest**, because it has the
   shallowest integration and already compiles under Embedded Swift;
2. **mjson C token/range adapter**, because its allocation-free raw-offset
   model best matches AxolotyWire;
3. **yyjson C fixed-arena adapter**, because it offers the strongest stated
   correctness contract and active maintenance;
4. **native Swift**, retained as the benchmark control and fallback.

Run only the cheap Rust static-library gate initially. Do not implement Coaty
schemas in Rust unless the toolchain and ABI results are compelling. Keep
ArduinoJson/RapidJSON as secondary candidates if the C shortlist fails.

The final choice should minimize **Axoloty-owned JSON grammar**, not merely
source dependencies. A small external tokenizer that leaves Unicode, numbers,
and strict validation to Axoloty does not solve the maintenance concern.
