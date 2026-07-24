# IO routing and SensorThings compatibility decisions (T-021)

Status: recorded keep/diverge/remove decisions for T-021, backed by the
evidence below. Where a gate is not yet satisfied by live capture, the
capability is marked **not yet tested** per the audit's requirement; it is
never marked compatible, divergent, or removable on a current failure alone.

Reference versions: CoatyJS `@coaty/core@2.4.0` (commit
`4a77168`); modern Swift = current `main`. Legacy CoatySwift 2.4.0 IO
directions are descoped by `LegacySwiftIOScopeDecision.md` (no macOS/Xcode
host this session).

## Evidence baseline

| Capability | Evidence |
|---|---|
| CoatyJS IO runner | `Tests/WireCompatibility/IO/coatyjs-io-runner.js` (roles: associate-source, actor, raw-source, external-source); smoke-tested JS source↔actor end-to-end against Mosquitto |
| Associate wire format | `AxolotyIoAssociateTests` (offline, 5 cases) + live modern→JS runner `IO/Live/run-io-associate.sh` (PASS: CoatyJS actor acked) + raw MQTT capture `.testing/wire/io/associate/io-associate.jsonl` |
| IoValue wire format | Live modern→JS capture: CoatyJS actor received `{"payload":42}` for a scalar publish (Axoloty wraps; CoatyJS expects the bare value) |
| JS number precision | Smoke run: `Int64.max` (9223372036854775807) round-trips through CoatyJS as 9223372036854776000 (float64) |

## Decisions

### Associate — generated route: KEEP (route/topic); DIVERGE (isExternalRoute handling)

The generated IOV route `coaty/3/<namespace>/IOV/<ioSourceId>` and the ASC
publication topic `coaty/3/<namespace>/ASC-<ioContextName>/<routerId>` are
identical between Axoloty and CoatyJS (asserted offline by
`AxolotyIoAssociateTests.generatedIoRouteUsesIoSourceObjectId` and
`associateEventEncodesGeneratedRouteFieldsAndIsExternalRoute`; confirmed live
by the modern→JS runner where CoatyJS subscribed to the route and received
the IoValue). Required fields `ioSourceId`, `ioActorId`, `associatingRoute`,
and `updateRate` round-trip in both directions.

**Divergence (defect):** Axoloty's `handleAssociate`
(`CommunicationManager.swift:557`) force-unwraps
`event.data.isExternalRoute!` on the actor-association path. Pinned CoatyJS
2.4.0's `AssociateEventData.toJsonObject` never serializes `isExternalRoute`
(confirmed by capture: the Associate payload contained only the four required
fields). Axoloty decodes that omitted field to `nil` (asserted offline by
`associateEventDecodesCoatyJSPayloadWithoutIsExternalRoute`), so an Axoloty
**actor** receiving a CoatyJS Associate would trap. This blocks the
JS → modern direction. Additionally, Axoloty *encodes* `isExternalRoute:
false` for a generated route (`encodeIfPresent` on a non-nil `Bool?`), an
asymmetry with CoatyJS that is benign for decoding (CoatyJS ignores the
field) but should be normalized.

**Remediation (#211):** force-unwrap replaced with `event.data.isExternalRoute ?? false`, regression test added, and Associate encoding normalized to omit the field when `false`. The JS → modern column is provisionally `Compatible with normalization` pending live re-run with the updated encoding.

### JSON IoValue: REMEDIATED (bare-value publish shipped)

Axoloty's `publishIoValue` now emits the bare JSON payload directly
(`CM+Publish.swift:170-176`), matching CoatyJS 2.4.0's wire shape. The fix
was shipped as part of the AnyCodable removal (#194) and the JSON value rename
(#204). Offline regression tests (`AxolotyIoValuePayloadTests`) lock in the
bare-value encode/decode round-trip for scalar and object JSON payloads. The
live modern→JS scenario still needs re-running to update the capture evidence;
the column is provisionally moved to `Compatible with normalization` based on
the offline assertion, pending live re-confirmation.

### Raw IoValue: REMEDIATED (byte overload shipped)

The raw path now calls the `[UInt8]` publish overload
(`CM+Publish.swift:170-171`), preserving the original byte sequence. Offline
regression tests cover empty, NUL-containing, and invalid-UTF8 raw payloads
(`AxolotyIoValuePayloadTests`). The live raw capture remains to be run;
the column is provisionally moved based on the offline evidence.

### External route, fan-out/transitions, negative cases, forward compat: PARTIALLY TESTED

Scenarios 4 (external route), 5 (fan-out/transitions), and 6 (negative IO cases live subset) are not yet backed by live capture. The CoatyJS runner implements the `external-source`, `raw-source`, and `actor` roles, and env-gated Swift tests exist for:
- Raw IoValue JS→modern (`WIRE_IO_RAW_JS_TO_MODERN_LIVE`)
- Raw IoValue modern→JS (`WIRE_IO_RAW_MODERN_TO_JS_LIVE`)
- External route JS→modern (`WIRE_IO_EXT_JS_TO_MODERN_LIVE`)

Live shell scripts and Makefile entries for these scenarios remain to be written.

Offline forward-compat tests (scenario 9) have been added:
- IoValueEventData with unknown fields (`ioValueDecodesPayloadWithUnknownFields`)
- IoValue raw payload with reordered keys (`ioValueDecodesRawPayloadWithReorderedKeys`)
- Associate with reordered JSON keys (`associateEventDecodesWithReorderedKeys`)
- Raw IoValue with unknown fields (`rawIoValueDecodesPayloadWithUnknownFields`)

SensorThings (scenarios 7-8) and lifecycle overlap (scenario 10) remain not tested.

Column: `Not tested`, with the harness in place for live execution.

### IoState API behavior: KEEP (not a wire contract)

`IoState` is explicitly internal and not published on MQTT
(`IoStateEvent.swift:15-16`); it is a local API-behavior assertion derived
from Associate handling. There is no cross-implementation wire contract to
diverge. KEEP.

### JS number precision: KEEP with normalization note

Pinned CoatyJS 2.4.0 represents `Int64.max` as a float64, losing precision
(9223372036854775807 → 9223372036854776000). This is a JS platform
constraint, not an Axoloty defect. Integer IoValues exceeding 2^53 must be
documented as not reliably round-tripping through a CoatyJS peer; Axoloty
preserves Int64 exactly. KEEP, with a normalization note in the matrix.

### SensorThings: PARTIALLY TESTED (field-schema fixtures captured)

No `@coaty/sensor-things` npm package (E404) and `@coaty/core@2.4.0` exports
no SensorThings types, so cross-implementation live coverage is not possible.
Per the audit, SensorThings defines no special MQTT event code; its wire
contract is ordinary Coaty object JSON with an `objectType` of
`coaty.sensorThings.*` over standard Advertise/Channel topics, so transport
compatibility reduces to the already-proven Advertise/Channel rows.

Offline field-schema fixture tests have been added
(`SensorThingsWireFixtureTests`): fully-populated and minimal objects of all
four types (FeatureOfInterest, Observation, Sensor, Thing), covering nested
UnitOfMeasurement, ObservedProperty, Polygon observedArea, CoatyTimeInterval,
heterogeneous raw JSON fields (metadata as null/object/string, result as
number/object/null/string), Unicode, forward-compat (unknown fields, reordered
keys, unknown observationType rejection), and omitted optionals.

Column: `Compatible with normalization` (transport proven via Advertise/Channel;
field-schema decode locked in offline). Live cross-implementation capture
remains unavailable due to the missing SensorThings npm package.

## Summary matrix update

See `CompatibilityMatrix.md` rows 20 (`Associate / IoState / IoValue`) and 22
(`SensorThings`) for the per-direction results. Both Associate and IoValue
defects have been remediated (#211, #212); the columns are provisionally
`Compatible with normalization` pending live re-confirmation.
