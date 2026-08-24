# IO routing and SensorThings compatibility decisions (T-021)

Status: Phase 4 ownership decision for T-021. G4 retains only the generic
Associate/IoValue protocol families and their current-runtime subjects.
Controller-based and rule-based IO routing, SensorThings models/controllers,
and automatic product registration are absent from G4 and deferred to G5.
Where a gate is not yet satisfied by live capture, the capability remains
**not yet tested**; it is never promoted by an offline mirror alone.

Reference versions: CoatyJS `@coaty/core@2.4.0` (commit
`4a77168`); modern Swift = current `main`. Legacy CoatySwift 2.4.0 IO
directions are descoped by `LegacySwiftIOScopeDecision.md` (no macOS/Xcode
host this session).

## Evidence baseline

| Capability | Evidence |
|---|---|
| CoatyJS IO runner | `Tests/Support/WireCompatibility/IO/coatyjs-io-runner.js` (roles: associate-source, actor, raw-source, external-source); smoke-tested JS source↔actor end-to-end against Mosquitto |
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

The current runtime decodes omitted `isExternalRoute` defensively and the
offline subject locks the required field-presence contract. The generated
route and ASC topic remain portable protocol behavior. Controller association
policy, automatic routing, and IoState publication are not G4 contracts.

### JSON IoValue: REMEDIATED (bare-value publish shipped)

The current runtime publishes the generic IoValue wire family through the
shared protocol/wire path. Portable encode/decode behavior is owned by the
`AxolotyWire` and `AxolotyProtocol` package tests; root product tests no longer
mirror the retired controller API. The live modern→JS scenario still needs
re-running to update the capture evidence, so the matrix remains partial.

### Raw IoValue: REMEDIATED (byte overload shipped)

The raw path is a generic wire concern and remains owned by the current
protocol/wire packages. Root controller tests and unverified raw fixtures are
not retained; the live raw capture remains to be run before claiming support.

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

### SensorThings: REMOVED FROM G4; DEFERRED TO G5

No `@coaty/sensor-things` npm package (E404) and `@coaty/core@2.4.0` exports
no SensorThings types, so cross-implementation live coverage is not possible.
Per the audit, SensorThings defines no special MQTT event code; its wire
contract is ordinary Coaty object JSON with an `objectType` of
`coaty.sensorThings.*` over standard Advertise/Channel topics, so transport
compatibility reduces to the already-proven Advertise/Channel rows.

The former root SensorThings fixture suite was a product-model mirror of the
retired controller hierarchy and is intentionally deleted in Phase 4. Portable
JSON and predicate behavior remains owned by the ObjectModel and Wire package
tests. A future G5 implementation must add schema, ownership, and
cross-implementation evidence together; no placeholder target or compatibility
shim is retained here.

## Summary matrix update

See `docs/wire-compatibility.md` rows 20 (`Associate / IoState / IoValue`) and 22
(`SensorThings`) for the current G4 ownership and gate status.
