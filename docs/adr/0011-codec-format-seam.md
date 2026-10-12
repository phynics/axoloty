---
status: accepted
---

# Open the codec format seam behind a format-neutral facade

[ADR 0008](./0008-axoloty-1-cbor-extension-profile.md) records that the public
wire codec protocols "cannot stay bound to the concrete JSON reader and
writer": either they gain a format seam or they leave the public API before
Axoloty commits to API stability. This ADR records the seam's shape. It is
the first implementation increment of
[epic #977](https://github.com/phynics/axoloty/issues/977) that changes
public API.

## Context

`WireDecodable` and `WireEncodable` were bound to the concrete JSON engine:
`WireReader` tokenized JSON and `WireWriter` emitted JSON. Every DTO decoded
and encoded exactly one format, so `axoloty/1` could not reuse the fourteen
DTO implementations without duplicating them or threading a second codec
family through `AxolotyProtocol`, the static runtime, and every transport
adapter.

The constraint that ruled out most designs: `coaty/3` JSON output must stay
byte-identical, because CoatyJS interoperability is a `coaty/3` property and
the wire-compatibility fixtures are captured against today's bytes.

## Decision

**Option A: a format-neutral facade.** `WireReader` and `WireWriter` remain
the public entry points and keep their accessor and writer method names
(`readUUID`, `readString`, `readInt`, `beginObject`, `writeTrustedRawField`,
…). A new `WireCodec` carries the binding-selected `WireProfile` and
constructs readers and writers whose engine is JSON (`coaty/3`) or
deterministic CBOR (`axoloty/1`). Every wire DTO decodes and encodes both
profiles from one implementation.

- **Engines behind the facade.** `WireReader` gains a CBOR engine that indexes
  the top-level CBOR map into the same bounded borrowed field index the JSON
  tokenizer fills, so accessors stay order-independent, allocation-free, and
  byte-borrowing. `WireWriter` gains a CBOR engine that writes into the same
  caller-owned buffer. The only format conditionals in the portable packages
  live behind these two facades and behind `WireCodec`.
- **`WireCodec` is the selection point.** A transport binding selects exactly
  one profile at composition time (ADR 0008) and forwards it through the
  codec. `AxolotyProtocol`'s `ProtocolProcessor` stores one codec, forwards it
  to every payload decode, encode, and raw-array walk, and contains no
  encoding conditional. Profile-specific walks that the protocol needs
  (deadvertise object IDs, decoded association routes, the bare IO value
  gate) moved into the facade as `readUUIDElements(_:_:)`,
  `copyDecodedString(_:into:)`, and `isValidBareValue(_:)`.
- **Deterministic writer.** The CBOR engine emits RFC 8949 §4.2.1 core
  deterministic encoding: definite lengths, shortest-form heads, and map keys
  in ascending order of their encoded bytes. It sorts the recorded chunks of
  one facade-built map with in-place block swaps, so no scratch buffer is
  allocated, and rejects duplicate keys. A facade-built map or array carries
  at most `WireBufferConfig.maxIndexedFields` (24) chunks — mirroring the
  reader's 24-slot index — so its head is one byte (two bytes for exactly 24
  chunks). Only one facade-built container may be open at a time; nested
  values must be pre-encoded and spliced, which is the only shape the event
  DTOs produce.
- **`coaty/3` is unchanged.** The default engine keeps the exact JSON
  tokenizer and writer bytes. The one DTO body touched (`IoStateWireData`)
  now treats an explicit `null` through the profile-neutral
  `readOptionalRaw(_:)`, which is byte-equivalent to the previous literal
  `null` comparison on JSON.

### Rejected alternatives

**Generic DTOs (protocols parameterized over the engine).** `WireDecodable`
would become `WireDecodable<Engine>` or expose associated reader/writer
types. Every conformance, every caller, and the static runtime's handler
tables would pay a generic-parameter tax, DTO values would stop having a
plain unparameterized type, and the object-model seams that already consume
`WireReader` would need to parameterize too.

**Schema-driven dual codecs.** Generate both codecs from one schema (the
macro family already builds object schemas). This couples the wire codec to
the object-model macro toolchain, hides the hot path from review, and still
leaves the protocol layer needing a format-neutral accessor vocabulary. The
facade keeps the codecs hand-written and visible, which is what the
bounded-memory invariants require.

**A second DTO family (`CBORWireData` et al.).** Fourteen parallel structs
double the codec surface, drift immediately, and force `AxolotyProtocol` to
branch on the profile — the exact conditional ADR 0008 forbids.

## Consequences

- The facade is the only sanctioned place for format conditionals. A review
  that finds `if cbor` (or a profile `switch`) in `AxolotyProtocol`, the
  static runtime, a transport adapter, or a DTO body is a defect: the
  behavior belongs behind `WireReader`, `WireWriter`, or `WireCodec`.
- `WireObjectFieldKind` gains `byteString` and `tag` for the CBOR-only lexical
  kinds; the JSON engine still produces only the original seven kinds.
- The `axoloty/1` bare IO value gate accepts any payload, including bytes
  that do not parse as CBOR: external IO routes carry application-defined
  bytes and every byte value opens a legal CBOR item, so no first-byte sniff
  exists. The bounded DTO decode at the handler remains the validation gate.
- JSON round-trip fixtures from the wire-compatibility corpus remain the
  regression authority for `coaty/3` byte identity; the parity suite replays
  every DTO through both profiles.
