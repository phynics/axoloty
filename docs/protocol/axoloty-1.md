# The `axoloty/1` CBOR wire profile

Status: accepted and implemented profile under
[epic #977](https://github.com/phynics/axoloty/issues/977). The profile
decisions below are settled by
[ADR 0008](../adr/0008-axoloty-1-cbor-extension-profile.md) and
[ADR 0009](../adr/0009-zenoh-carries-only-axoloty-1.md). This document is the
profile contract for the shipped codec, routes, trace parity, and embedded
consumer surfaces.

`axoloty/1` carries the Coaty Core Profile 3 event families and object
semantics unchanged. Only the payload encoding differs: CBOR (RFC 8949)
instead of JSON. `coaty/3` stays sealed and unchanged; see
[coaty-core-3.md](./coaty-core-3.md).

## Route layout

```
axoloty/1/<namespace>/<eventType>[:<filter>]/<sourceId>[/<correlationId>]
```

The layout is identical to `coaty/3` except for the prefix. The same event
codes (`ADV`, `DAD`, `CHN`, `ASC`, `IOV`, `DSC`, `RSV`, `QRY`, `RTV`, `UPD`,
`CPL`, `CLL`, `RTN`), the same one-way/two-way correlation rule, and the same
bounds apply.

The route prefix is the authoritative encoding signal on every transport,
because subscriptions partition on routes and MQTT 3.1.1 has no content type.
A transport that supports encoding metadata (for example the Zenoh `Encoding`
value) labels the payload `application/cbor` as an advisory only. A receiver
must never decode based on the content-type hint alone.

Each transport binding selects exactly one profile at composition time.
Version 1 has no runtime negotiation, no dual mode, and no dynamic profile
registration. `AxolotyProtocol` and the static runtime carry no encoding
conditional.

## Deterministic encoding

Writers emit RFC 8949 §4.2.1 core deterministic encoding:

- Definite lengths only. Indefinite-length strings, arrays, and maps are
  never emitted.
- Shortest-form arguments. Every integer, string length, and container count
  uses the shortest possible head.
- Preferred simple-value form. Simple values 0–23 use the direct form; the
  one-byte extension is used only for values 24–255.
- Floating point uses the shortest lossless width of single or double.
  Half-precision is read but not emitted.
- Map keys are sorted by their deterministic encoded bytes. Text keys sort by
  length first, then bytewise.

Readers reject:

- indefinite-length items;
- non-minimal integer, length, and simple-value encodings;
- semantic tags outside the allow-list;
- duplicate map keys (text, byte-string, and integer keys);
- container nesting beyond the compile-time bound;
- invalid UTF-8 in text strings.

## Profile decisions

### Map keys (CD-5)

`axoloty/1` uses **text keys** that match the `coaty/3` field names. The
epic's size measurement shows a further reduction from a versioned
integer-key registry, but text keys keep one schema, one decoder shape, and a
readable CDDL for both profiles. A registry is deferred; adopting one later
requires a new `axoloty/2` profile, not a silent change to `axoloty/1`.

### UUID representation

Writers emit a UUID as **tag 37 followed by a 16-byte byte string**
(`#6.37(h'...')`). This is the RFC 8949 / RFC 4122 canonical form and is
smaller than the 36-byte hyphenated text form. Readers accept both the tag-37
byte string and the canonical 36-byte hyphenated text string, so a
non-conforming peer stays decodable. A wrong tag or a non-16-byte payload is
rejected as `malformedUUID`.

### Semantic tags

The reader allow-list is:

| Tag | Meaning |
|---|---|
| 1 | Epoch-based date/time |
| 37 | UUID |

Every other tag is rejected as `cborUnsupportedTag`.

## Bounds

| Bound | Value | Source |
|---|---|---|
| Route length | 256 bytes | ``WireBufferConfig.maxTopicLength`` |
| Payload length | 2,048 bytes | ``WireBufferConfig.maxPayloadSize`` |
| Container nesting | 32 | ``WireBufferConfig.maxCBORNestingDepth`` |
| Indexed top-level fields | 24 | ``WireBufferConfig.maxIndexedFields`` |

The hot path stays allocation-free: the reader walks a borrowed buffer and
returns borrowed ``ByteSlice`` values; the writer encodes into a caller-owned
fixed buffer.

## CDDL

```cddl
; axoloty/1 core event payloads (RFC 8949 CBOR)
; Routes: axoloty/1/<namespace>/<event>/<sourceId>[/<correlationId>]

uuid = #6.37(bytes .size 16)

; Advertise / Deadvertise
advertise   = { "object": object, ? "privateData": any }
deadvertise = { "objectIds": [* uuid] }

; Channel
channel = {
  ? "object": object,
  ? "objects": [* object],
  ? "privateData": any,
}

; Associate / IoValue
associate = {
  "ioSourceId": uuid,
  "ioActorId": uuid,
  ? "associatingRoute": tstr,
  ? "isExternalRoute": true,
  ? "updateRate": uint,
}
ioValue = { "payload": any }

; Discover / Resolve
discover = {
  ? "externalId": tstr,
  ? "objectId": tstr,
  ? "objectTypes": [* tstr],
  ? "coreTypes": [* tstr],
}
resolve = {
  "object": object,
  ? "relatedObjects": [* object],
  ? "privateData": any,
}

; Query / Retrieve
query = {
  ? "objectTypes": [* tstr],
  ? "coreTypes": [* tstr],
  ? "objectFilter": any,
  ? "objectJoinConditions": [* any],
}
retrieve = { "objects": [* object], ? "privateData": any }

; Update / Complete
update   = { "object": object }
complete = { ? "object": object, ? "privateData": any }

; Call / Return
call   = { ? "parameters": any, ? "filter": any }
return = { ? "result": any, ? "executionInfo": any, ? "error": any }

object = {
  ? "objectId": uuid,
  ? "objectType": tstr,
  ? "coreType": tstr,
  ? "name": tstr,
  * tstr => any,
}
```

The CDDL shows the emitted field set. Map keys are sorted by their
deterministic encoded bytes, so key order in a payload is not the order above.
An object payload keeps unknown fields and numeric lexemes, matching the
`coaty/3` object-model contract. Two field forms are deliberate and are
locked by the golden corpus:

- An object's `objectId` is a tag-37 `uuid`, but `discover.objectId` is a
  plain text UUID string, matching the pinned CoatyJS shape.
- `retrieve` encodes `objects`; the reader also accepts the legacy `object`
  field so an older peer stays decodable.

See [wire-value-mapping.md](../wire-value-mapping.md) for the JSON/CBOR value
classes and the raw-field retention rules.

## Error model

CBOR decode failures reuse the structured ``WireDecodeError``. The CBOR-
specific reasons are `cborIndefiniteLength`, `cborInvalidAdditionalInfo`,
`cborNonMinimalInteger`, `cborUnexpectedMajorType`, `cborUnsupportedTag`,
`cborDuplicateMapKey`, `cborNestingTooDeep`, and
`cborUnsupportedSimpleValue`. Shared reasons such as `unexpectedEndOfInput`,
`invalidUTF8`, `integerOverflow`, and `malformedUUID` keep their meaning.

## Implementation status

| Surface | State |
|---|---|
| Route prefix, profile enum, profile-scoped validation | Implemented |
| Bounded deterministic CBOR reader and writer | Implemented |
| `WireDecodable`/`WireEncodable` DTO codec seam (format-neutral, [ADR 0011](../adr/0011-codec-format-seam.md)) | Implemented |
| Raw/custom CBOR payload retention | Implemented ([wire-value-mapping.md](../wire-value-mapping.md)) |
| Facade accessors for the CBOR-only float, byte-string, and tag kinds | Implemented (consumed by `IoValueWireData`) |
| Host-generated envelopes through the profile-aware writer | Implemented ([wire-value-mapping.md](../wire-value-mapping.md)) |
| Zenoh binding on `axoloty/1` only | Implemented |
| Golden `coaty/3`/`axoloty/1` corpus with independent CBOR decode | Implemented |
| Trace-parity gate | Implemented |
| Embedded consumer contract surface | Implemented |

Every row is implemented under epic #977. `AxolotyWire` ships the CBOR
primitives and `axoloty/1` routes with RFC 8949 Appendix A conformance
vectors. The host runtime builds its generated Identity Advertise and
Deadvertise, IO endpoint Advertise, and conformance error and empty envelopes
through the same profile-aware writer; it does not transcode `coaty/3` JSON to
CBOR. The IO endpoint metadata re-encoder walks the fixed first-party schema
and rejects an unknown field, a fractional number, or an integer that does not
fit `Int` exactly with `ProtocolError.malformedPayload`. The frozen golden
corpus under
`Tests/AxolotyTests/WireCompatibility/Golden` covers every event family and
DTO field-presence variant, and the wire tool independently decodes every CBOR
golden with `cbor-x`. The `wire-cbor` tier runs the golden corpus and the
host/static trace-parity replay on every pull request; `coaty/3` JSON bytes are
unchanged. See [../testing.md](../testing.md) for the tier contract. The facade
also reaches the `axoloty/1`-only float, byte-string, and tag kinds through
`WireReader.readFloat(_:)`, `WireReader.readByteString(_:)`,
`WireReader.readTag(_:)`, `WireWriter.writeFloat64(_:)`,
`WireWriter.writeByteString(_:)`, and `WireWriter.writeTag(_:)` plus their
field variants. `IoValueWireData` consumes the readers through its real
`payload` field: `floatPayload`, `byteStringPayload`, and `tagPayload` expose
the CBOR-only lexical kinds, and each view is `nil` under `coaty/3` JSON.
`OwnedIoValueWireData(cborFloat:)`, `OwnedIoValueWireData(cborByteString:)`,
and `OwnedIoValueWireData(cborTag:taggedItem:)` consume the standalone writers
to build one bare `axoloty/1` payload item. The raw `payload` remains
authoritative, so `coaty/3` bytes and field presence are unchanged and a peer's
exact `axoloty/1` float width is preserved on re-encode.

## CBOR-only consumers

A CBOR-only `AxolotyWire` build, produced with `--disable-default-traits`, does
not link `_JSONCore`. Two known limitations apply today. They are recorded
here and are not fixed in the profile code:

1. `BorrowedMessage.ownedEvent()` and `BorrowedMessage.reader()` are gated by
   `#if canImport(_JSONCore)` and are absent from a CBOR-only build. Decode
   through `WireCodec.reader(bytes:length:)` and
   `BorrowedWireEvent.init(eventType:from:)` instead. See
   [../embedded-consumer-contract.md](../embedded-consumer-contract.md) for the
   supported build shape.
2. `ProtocolTraceRuntimeReplay.seedObject` in
   `AxolotyProtocolTraceTestSupport` hardcodes a JSON Advertise payload, so the
   trace-parity replay seed path is JSON-only today. This is test support, not
   production code: no shipping path switches on the active profile. If a
   CBOR-only replay seed is required, that helper must encode the seed with the
   route profile.
