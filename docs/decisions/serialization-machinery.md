# Architecture decision: legacy host serialization machinery

## Decision

**Retain all legacy host serialization machinery for 0.2.** No components
are dead code. Every component has named production callers and serves
behavior that `AxolotyWire` does not yet provide.

## Classification

| Component | File | Classification | Callers |
|---|---|---|---|
| `PayloadCoder` | `Source/Common/PayloadCoder.swift` | Public production API | 8 production files, 14 test files |
| `Codable+JSON` | `Source/Common/Codable+JSON.swift` | Internal production dependency | 13 production files (privateData, config extras) |
| `AnyCoatyObjectDecodable` | `Source/Common/AnyCoatyObjectDecodable.swift` | Public production API | 7 production files (event decode dispatch) |
| `Decoder+Context` | `Source/Common/Decoder+Context.swift` | Internal production dependency | 3 production files (context stack plumbing) |
| `RawJSONObjectContext` | `Source/Common/RawJSONObjectContext.swift` | Internal production dependency | 3 production files (raw JSON tree retention) |
| `RawJSONValue` | `Source/Common/RawJSONValue.swift` | Internal production dependency | 11 production files (raw JSON value model) |
| `CoreTypeKeysContext` | `Source/Common/AnyCoatyObjectDecodable.swift` | Internal production dependency | 2 production files (class-hierarchy key accumulation) |
| `CommunicationEvent.json` | `Source/Communication/Events/CommunicationEvent.swift` | Public production API | 2 production files (publish + last-will) |
| `CoatyObject.json` | `Source/Model/Core Types/CoatyObject.swift` | Public production API | 2 production files (ObjectMatcher, FilterOperand) |
| `register(objectType:)` | `Source/Model/Core Types/CoatyObject.swift` | Public production API | 16 production files (type registration) |
| `decodeCustom` | `Source/Model/Core Types/CoatyObject.swift` | Public production API | 0 production (downstream consumer API), 1 test |

## Rationale for retention

### Dynamic object-type dispatch (`AnyCoatyObjectDecodable`)

`AxolotyWire` has no concept of dynamic object-type → Swift-class
resolution. The wire DTOs carry objects as opaque `ByteSlice` raw JSON.
The host runtime's `AnyCoatyObjectDecodable` resolves `objectType` to a
registered `CoatyObject` subclass at decode time, supporting:

- Dynamically registered application object classes.
- Core-type fallback for unregistered object types.
- Unknown object-type preservation as `CoatyObject` with `custom` dict.

This is the host's primary extensibility mechanism. Replacing it requires
a `CoatyObject` encode/decode path in `AxolotyWire`, which is out of scope
for 0.2.

### `[String: Any]` encoding (`Codable+JSON`)

`AxolotyWire` avoids `Any` entirely; wire DTOs use `ByteSlice` for opaque
fields. The host `privateData: [String: Any]?` API on every event type
routes through `Codable+JSON`. Replacing this requires either removing
the `privateData` API (a breaking change) or adding a typed alternative
(a design decision beyond 0.2).

### Raw JSON tree retention (`RawJSONObjectContext`, `RawJSONValue`)

`AxolotyWire.WireReader.readRaw(_:)` returns raw JSON as `ByteSlice` —
the same conceptual capability. However, `CoatyObject.rawJSONObject`
(used by `ObjectMatcher` and `FilterOperand` for filter-path resolution)
depends on the Ikiga `JSONObject` tree, not borrowed bytes. Replacing
this requires migrating the filter evaluation to a wire-native path,
which is a larger refactor.

### Context stack (`Decoder+Context`)

This plumbing exists only because `Foundation.JSONDecoder` copies
`userInfo` into nested containers, preventing shared mutable state across
a recursive `init(from:)` chain. `AxolotyWire`'s single-pass `WireReader`
needs no shared context. This component becomes dead only when the host
stops using `Codable` for `CoatyObject` decoding — which is not happening
in 0.2.

### `.json` convenience properties (`CommunicationEvent.json`, `CoatyObject.json`)

These non-throwing `String` accessors back every `publish*` call in
`CommunicationManager` and the last-will deadvertise. `AxolotyWire`
provides `WireEncodable.encode(to:)` into a `WireWriter` buffer, but no
non-throwing `String` convenience exists on the wire DTOs. Replacing
requires wiring the publish path to `WireWriter` — a transport-layer
change beyond 0.2.

## AxolotyWire coverage gap

| Capability | AxolotyWire status |
|---|---|
| Event DTO encode/decode | ✅ `WireDecodable`/`WireEncodable` + DTOs |
| `CoatyObject` encode/decode | ❌ No class-hierarchy support |
| Dynamic type registration | ❌ No class registry |
| `privateData: [String: Any]?` | ❌ Uses `ByteSlice` instead |
| Filter-path resolution | ❌ `ObjectMatcher` needs Ikiga tree |
| `.json` String convenience | ❌ No non-throwing String accessor |

## Behavior test coverage

The following scenarios are tested in `SerializationAuditTests.swift`
and existing test suites:

| Scenario | Test file |
|---|---|
| Registered custom object decoding | `SerializationAuditTests.swift` |
| Unknown object-type fallback | `SerializationAuditTests.swift` |
| Custom-property preservation | `SerializationAuditTests.swift` + `DeterministicFuzzTests.swift` |
| Nested object decoding | `SerializationAuditTests.swift` |
| Missing core-type discriminator | `SerializationAuditTests.swift` (throws) |
| Invalid core-type discriminator | `SerializationAuditTests.swift` (throws) |
| Missing object-type discriminator | `SerializationAuditTests.swift` (throws) |
| Encoding failure → AxolotyError | `SerializationAuditTests.swift` + `PayloadCoderTests.swift` |
| Decoding failure → AxolotyError | `SerializationAuditTests.swift` |
| RawJSONObject retention | `SerializationAuditTests.swift` + `IkigaJSONDecoderSeamTests.swift` |
| CommunicationEvent.json stability | `SerializationAuditTests.swift` |
| CoatyObject.json stability | `SerializationAuditTests.swift` |
| Malformed/truncated rejection | `DeterministicFuzzTests.swift` |
| CoatyJS fixture behavior | `WireFixtureTests.swift` |
| Context stack parity | `IkigaJSONDecoderSeamTests.swift` |

## Conclusion

Issue #397 supersedes the earlier communication-path disposition:

- MQTT ingress decodes an AxolotyWire event once and owns it before async
  delivery. IO routing and SensorThings no longer call `PayloadCoder`.
- `CommunicationEvent.json` and its publication callers were removed. Manager
  publications and the MQTT last will use `OwnedWireEvent.encode(to:)`.
- `PayloadCoder`, decoder context, `RawJSONObjectContext`, and IkigaJSON
  `JSONObject` remain only for the host object-model compatibility surface:
  runtime class hydration, unknown-type custom fields, `CoatyObject.json`, and
  filter-path evaluation. They are not event codecs and do not leak into
  AxolotyWire.
- Configuration and persistence Codable uses remain unrelated and unchanged.

There is no runtime dual-codec switch. Shipping communication always uses
AxolotyWire; retained JSON machinery operates only on nested host models.
