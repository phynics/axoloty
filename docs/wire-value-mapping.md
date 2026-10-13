# Wire value mapping and raw-field retention

This note records how Axoloty relates `coaty/3` JSON values to `axoloty/1`
CBOR values, and how the owned raw-field path keeps each value in the profile
that produced it. It follows RFC 8949 §6.1 (converting from JSON to CBOR) and
§6.2 (converting from CBOR to JSON). The profile definitions live in
[protocol/axoloty-1.md](./protocol/axoloty-1.md) and
[protocol/coaty-core-3.md](./protocol/coaty-core-3.md).

## One profile per value

The route prefix selects exactly one profile for a payload. A raw field is an
opaque byte slice with the profile that produced it. Axoloty does **not**
transcode a raw field between profiles:

- Within one profile, an owned raw field keeps the exact input bytes, so a
  round trip is byte-for-byte.
- Across profiles, encoding a raw field into a different-profile writer is
  rejected with `WireEncodeError.profileMismatch`.

This is what makes the JSON number and CBOR value cases below safe. Axoloty
never applies a generic RFC 8949 §6.1 or §6.2 conversion that could silently
lose information.

## Host-generated envelopes

The host runtime generates Identity Advertise and Deadvertise, IO endpoint
Advertise, and the conformance error and empty envelopes. Each envelope is
built through the encoder of the profile that carries it. `coaty/3` keeps its
sealed JSON bytes; `axoloty/1` is written field by field through `WireWriter`,
so a UUID becomes a tag-37 byte string, a string becomes a UTF-8 text string,
and an integer keeps its exact value. The host runtime has no generic
JSON-to-CBOR transcode on this path.

The object model stores IO endpoint metadata as sealed `coaty/3` JSON. For
`axoloty/1`, the host runtime re-encodes the fixed first-party metadata schema
from that JSON, field by field. It rejects rather than drops or coerces:

- an unknown top-level field is rejected with `ProtocolError.malformedPayload`,
  because silently losing a caller field would change the advertised object;
- a number that is fractional or that does not fit `Int` exactly is rejected
  with `ProtocolError.malformedPayload` instead of becoming a `float64` or an
  infinity;
- an explicit `null` for an optional field is preserved as CBOR `null`.

## Value classes

### Numbers

| Source value | `coaty/3` JSON | `axoloty/1` CBOR | Lossless? |
|---|---|---|---|
| Integer within IEEE 754 double range | Integer lexeme (`1`, `-42`) | Major type 0 or 1, shortest head | Yes |
| Integer beyond double precision (for example `2^60 + 1`) | Integer lexeme | Major type 0 or 1 (exact) | Yes, CBOR is exact; JSON text is exact |
| Fractional decimal with a binary-exact value (`0.5`) | Number lexeme (`0.5`) | Major type 7 float or a scaled integer, as chosen by the producer | Yes within a profile |
| Fractional decimal without a binary-exact value (`0.1`) | Number lexeme (`0.1`) | Major type 7 float | Not across profiles; retained as text or as a float within one profile |
| Exponent form (`1e2`, `1e999`) | Number lexeme | Major type 7 float, or rejected when it overflows | Not across profiles |
| Overflowing integer literal | Number lexeme; the object model keeps the lexeme | Rejected unless it fits a major-type integer or float | No generic mapping |

RFC 8949 §6.1 warns that JSON numbers are arbitrary-precision decimals while
CBOR numbers are finite integers and IEEE 754 floats, so a generic conversion
is not an inverse. Axoloty keeps the lexeme on the JSON side and the encoded
item on the CBOR side. It never converts one to the other.

### Strings and bytes

| Value | `coaty/3` JSON | `axoloty/1` CBOR |
|---|---|---|
| Text content | JSON string with escapes | Major type 3 UTF-8 text string |
| Byte string | No JSON equivalent | Major type 2 byte string |
| Object or map key | String | Text string (the profile rejects non-text keys) |
| UUID | 36-byte hyphenated string | Tag 37 over a 16-byte byte string |

A `coaty/3` string field carries encoded string content, including JSON escape
sequences. The matching `axoloty/1` field carries plain UTF-8 content. Because
the profile tags the field, each value is decoded by its own rule:
`copyDecodedString` decodes JSON escapes for `coaty/3` and validates UTF-8 for
`axoloty/1`.

### CBOR-only forms

These values exist in CBOR and have no JSON representation. Axoloty retains
them in an `axoloty/1` raw field and rejects any attempt to encode them into a
`coaty/3` writer:

| Form | Encoding | JSON result |
|---|---|---|
| Byte string | Major type 2 | None |
| `NaN`, `Infinity`, `-Infinity` | Major type 7 float | None; JSON forbids them |
| Negative zero | Major type 7 float | Collapses to `0`; lossy |
| Semantic tag outside the allow-list | Major type 6 | None |
| Big integer (tags 2 and 3) | Major type 6 | None; outside the `axoloty/1` allow-list and rejected |
| Map with non-text keys | Major type 5 | None; the `axoloty/1` reader rejects it |
| Indefinite-length item | Major type 2–5 with additional information 31 | None; the deterministic profile rejects it |

RFC 8949 §6.2 reaches the same limits from the CBOR side: byte strings, tags,
and non-finite floats have no direct JSON form, and a generic converter must
choose an application-specific representation.

## Rejection and retention rules

`OwnedWireDataValidation` enforces one rule per profile:

- `coaty/3`: the field must be a complete JSON value of the required shape, or
  encoded JSON string content for a text field.
- `axoloty/1`: the field must be exactly one complete CBOR item of the
  required shape, or valid UTF-8 content for a text field. The reader rejects
  tags outside the allow-list, indefinite lengths, non-minimal heads, trailing
  bytes, duplicate map keys, and excessive nesting, and reports each with the
  structured `WireDecodeError` reason. Ascending map-key order is a writer
  rule, not a reader rule: a retained raw field keeps a peer's key order
  unchanged, and `OwnedRawCBORBoundaryTests` locks that tolerance.

An owned value records its profile. `OwnedWireEvent.encodedBytes()` selects the
writer from that profile, and `OwnedWireEvent.encode(to:)` rejects a writer
whose profile differs. One owned raw field is bounded by
`WireBufferConfig.maxPayloadSize` (2,048 bytes), the same limit as the wire
payload, so validation rejects a larger field with
`WireDecodeError.payloadExceedsLimit` before ownership is published.
Validation is necessary but not sufficient for encodability: the enclosing
event adds its own keys and structure. `OwnedWireEvent.encode(to:)` remains
the authoritative fit check and throws `WireEncodeError.bufferOverflow` when an
accepted field does not fit the writer. The result is that:

- a JSON raw field round-trips through the JSON path unchanged;
- a CBOR raw field round-trips through the CBOR path unchanged, including
  byte strings, `NaN`, negative zero, and UUIDs encoded as tag 37;
- a cross-profile round trip fails loudly instead of losing a value.

## Related code

- `OwnedWireDataValidation.swift` — per-profile raw-field validation.
- `OwnedWireData.swift` — owned structs that carry a `profile` tag.
- `WireEvents.swift` — `OwnedWireEvent.profile` and the encode profile guard.
- `BorrowedMessage.swift` — route-profile reader selection and `ownedEvent()`.
- `WireWriter.swift` — `WireWriter.profile` and
  `WireEncodeError.profileMismatch`.

## Tests

`OwnedRawCBORBoundaryTests` proves the CBOR retention and rejection rules;
`OwnedRawJSONBoundaryTests` and `WireCodecParityTests` keep the `coaty/3` byte
identity and the per-DTO profile parity.
