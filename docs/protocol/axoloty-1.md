# The `axoloty/1` CBOR wire profile

Status: accepted profile, first implementation increment in progress under
[epic #977](https://github.com/phynics/axoloty/issues/977). The profile
decisions below are settled by
[ADR 0008](../adr/0008-axoloty-1-cbor-extension-profile.md) and
[ADR 0009](../adr/0009-zenoh-carries-only-axoloty-1.md).

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

advertise = { "object": object }
deadvertise = { "objectIds": [* uuid] }
channel = { "object": object, ? "channelId": tstr }
associate = { "ioSourceId": uuid, "ioActorId": uuid, ? "object": object }
ioValue = { "payload": any, ? "object": object }

discover = { "objectTypes": [* tstr] }
resolve = { "object": object }
query = { "objectTypes": [* tstr] }
retrieve = { "object": object }
update = { "object": object }
complete = { "object": object }
call = { "parameters": any, ? "filter": any }
return = { "result": any }

object = {
  ? "objectId": uuid,
  ? "objectType": tstr,
  ? "name": tstr,
  * tstr => any,
}
```

The object payload keeps unknown fields and numeric lexemes, matching the
`coaty/3` object-model contract.

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
| Raw/custom CBOR payload retention | Follow-up under #977 |
| Zenoh binding on `axoloty/1` only | Follow-up under #977 |
| Golden corpus and trace-parity gate | Follow-up under #977 |
| Embedded consumer contract surface | Follow-up under #977 |

The first increment ships `AxolotyWire`'s CBOR primitives and `axoloty/1`
routes with RFC 8949 Appendix A conformance vectors. The remaining rows are
tracked by epic #977 and do not change the decisions above.
