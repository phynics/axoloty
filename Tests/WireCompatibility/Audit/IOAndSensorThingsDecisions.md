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

**Required remediation (follow-up PR, not this one):** replace the
force-unwrap with `event.data.isExternalRoute ?? false`, add a regression
test that an Associate without `isExternalRoute` associates an actor without
trapping, and re-run the JS → modern live direction. Until then the JS →
modern column is `Intentional divergence (defect)`.

### JSON IoValue: DIVERGE (defect — wire-format mismatch)

Axoloty's `IoValueEvent.json` wraps the value under a `payload` key
(`IoValueEventData.encode`; asserted offline by
`ioValueEventWrapsJsonValueUnderPayloadKey` → `{"payload":42}`). Pinned
CoatyJS 2.4.0 publishes the bare JSON value (its
`IoValueEventData.toJsonObject` returns the payload directly; confirmed by
capture where the scalar IoValue was the two-byte string `42`). The live
modern→JS runner proved the consequence: the CoatyJS actor received
`{"payload":42}` — a structurally wrong value — and acked on receipt.

This is the JSON-mode form of the raw-IoValue overload defect the audit
flagged (`IoSourceController.swift:250-257` → `CM+Publish.swift:454-460`):
`publishIoValue` sends `event.json` through the String publish overload
rather than emitting the raw payload value CoatyJS expects. Per the audit,
wire-spelling divergence is "not acceptable accidental divergence."

**Required remediation (follow-up PR):** publish the bare value (not the
wrapped event) for JSON IoValues so the wire matches CoatyJS, add a
regression test locking in the bare-value wire shape, and record a migration
note. Until then both IoValue columns are `Intentional divergence (defect)`.

### Raw IoValue: DIVERGE (defect — code-level, capture pending)

The audit identified that the raw path constructs an `IoValueEvent` but sends
`event.json` (JSON-wrapped bytes) via the String overload instead of the byte
overload at `CommunicationManager.swift:390-400`. The `raw-source` role is
implemented in the CoatyJS runner, but the live raw capture (Task 4 scenario
3, including NUL and invalid UTF-8) was not run this session. Recorded as a
defect on code-level evidence; the live capture remains to confirm the exact
bytes and CoatyJS decode behavior. Column: `Not tested (defect suspected)`.

### External route, fan-out/transitions, negative cases: NOT YET TESTED

Scenarios 4 (external route), 5 (fan-out/transitions), and 6 (negative IO
cases) are not backed by live capture this session. The CoatyJS runner
implements the `external-source` role and deterministic multi-actor IDs are
defined, so the harness is in place; the captures remain to be run. Columns:
`Not tested`.

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

### SensorThings: NOT YET TESTED (reduces to Advertise/Channel compatibility)

There is no `@coaty/sensor-things` npm package (E404) and `@coaty/core@2.4.0`
exports no SensorThings types. Per the audit, SensorThings defines no special
MQTT event code; its wire contract is ordinary Coaty object JSON with an
`objectType` of `coaty.sensorThings.*` carried over standard Advertise/Channel
topics. SensorThings compatibility therefore reduces to the already-established
Advertise/Channel compatibility (`Compatible with normalization` in the
matrix), plus the field-schema fixtures (Task 8) and forward-compat cases
(Task 9) which are not yet captured. The four object types
(`FeatureOfInterest`, `Observation`, `Sensor`, `Thing`) and their nested
fields (`UnitOfMeasurement`, `ObservedProperty`, polygon `observedArea`,
heterogeneous `AnyCodable`) are defined in `Source/SensorThings/` and
exercised same-process by `Tests/SensorThings/`. Columns: `Not tested`, with
the note that the transport layer is already proven compatible.

## Summary matrix update

See `CompatibilityMatrix.md` rows 20 (`Associate / IoState / IoValue`) and 22
(`SensorThings`) for the per-direction results. Open remediation items
(isExternalRoute force-unwrap; JSON/raw IoValue wire format) are tracked as
intentional divergences pending their follow-up PRs; the Phase 6 epic closes
with those recorded, mirroring how `qos-1`/`qos-2` closed as approved
divergences.
