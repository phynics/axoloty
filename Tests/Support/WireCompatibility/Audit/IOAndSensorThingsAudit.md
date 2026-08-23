# IO routing and SensorThings wire-compatibility audit

Status: evidence inventory for T-021. This document does not make the final
keep/diverge/remove decisions; it defines the evidence required to make them.

## Protocol inventory

All Coaty protocol topics use protocol version 3 and the publication shape
`coaty/3/<namespace>/<event-level>/<source-id>`. One-way subscriptions replace
namespace and source ID with `+` as needed. The event codes are `ASC` for
Associate and `IOV` for IoValue.

| Capability | Publication topic | Payload on MQTT | Source entrypoints |
|---|---|---|---|
| Associate | `coaty/3/<namespace>/ASC-<io-context-name>/<router-identity-id>` | JSON event containing `ioSourceId`, `ioActorId`, optional `associatingRoute`, optional `isExternalRoute`, and optional `updateRate` | `IoRouter.associate` / `disassociate`; `CommunicationManager.publishAssociate`; `_observeAssociate`; `handleAssociate` |
| Generated IoValue route | `coaty/3/<namespace>/IOV/<io-source-id>` | The route itself is carried in `Associate.associatingRoute` | `CommunicationManager.createIoRoute`; `IoRouter.associate` |
| External IoValue route | Application-supplied `IoSource.externalRoute` | The route is carried in `Associate.associatingRoute`, with `isExternalRoute: true` | `IoRouter.associate`; `CommunicationTopic.isRawTopic`; MQTT receive dispatch |
| IoValue, JSON mode | The source's currently associated route | JSON encoding of `IoValueEventData`, whose `payload` is the JSON-compatible value | `IoSourceController.publish`; `IoValueEvent.with`; `publishIoValue`; `observeIoValue` |
| IoValue, raw mode | The source's currently associated route | Intended contract is raw bytes, but the current publish path calls `publish(topic:message:)` with `event.json`, which encodes the byte array under `payload`. A reference capture must resolve this discrepancy | Same entrypoints as JSON mode plus `CommunicationClient.rawMQTTMessages` |
| IoState | No topic: explicitly an internal, non-MQTT event | None. It is derived locally from Associate handling and shutdown | `observeIoState`; `handleAssociate`; `unobserveIoStateAndValue` |
| SensorThings objects | Ordinary Coaty topics (`ADV`, `CHN`, `DSC`/`RSV`, `QRY`/`RTV`) with their normal filters/correlation IDs | Ordinary Coaty object/event JSON with one of the SensorThings object types below | SensorThings model Codable implementations; Sensor/Thing source and observer controllers |

Topic construction is defined in
`Source/Communication/Misc/CommunicationTopic.swift:216-259`; protocol name and
version in `CommunicationConstants.swift:15-17`; event codes in
`CommunicationEventType.swift:9-16`. Associate publication is assembled in
`CM+Publish.swift:467-477` and its wildcard subscription in
`CM+Observe.swift:452-478`. Generated IOV routes are created in
`CommunicationManager.swift:453-457` using the IoSource object ID, not the
publishing agent identity. IoValue is suppressed until the source has an
association (`CM+Publish.swift:448-460`).

### IO payload and behavior details to preserve

- Association is indicated by presence of `associatingRoute`; omission means
  disassociation. Optional-field *presence* must not be normalized away.
- The default generated route uses the IoSource ID. Associate itself uses the
  router identity ID in its topic.
- An external route may be outside `coaty/`; such traffic is dispatched as raw
  MQTT traffic. Both a protocol IOV route and an arbitrary external route need
  coverage.
- One source may feed multiple actors through one route. Reassociation and
  disassociation alter subscriptions and local association state.
- JSON and binary values are selected by `useRawIoValues`. Source and actor
  `valueType` and `useRawIoValues` must agree for the default router.
- Current Swift constructs a raw `IoValueEvent` in
  `IoSourceController.swift:250-257`, but `publishIoValue` sends `event.json`
  through the String overload (`CM+Publish.swift:454-460`) even though a byte
  overload exists (`CommunicationManager.swift:390-400`). Treat this as an
  unresolved compatibility candidate, not proof that JSON-wrapped bytes are
  the intended wire contract.
- `IoState` carries `hasAssociations` and, for a source only, the effective
  `updateRate`. It is an API-behavior assertion, not a wire fixture
  (`IoStateEvent.swift:11-17`, `CommunicationManager.swift:497-518`).
- The Associate decoder permits missing `isExternalRoute`, while current
  handling force-unwraps it when associating an actor
  (`CommunicationManager.swift:489-492`). Capture whether each reference
  producer always emits this field before calling the behavior compatible.

## SensorThings schema inventory

SensorThings defines no special MQTT event code. Compatibility is the combined
contract of standard event topics and these registered object schemas:

| Object type | Wire-significant model fields beyond CoatyObject |
|---|---|
| `coaty.sensorThings.FeatureOfInterest` | `description`, `encodingType`, `metadata` |
| `coaty.sensorThings.Observation` | `phenomenonTime`, `result`, `resultTime`, optional `resultQuality`, `validTime`, `parameters`, `featureOfInterest` |
| `coaty.sensorThings.Sensor` | `description`, `encodingType`, `metadata`, `unitOfMeasurement`, `observationType`, optional `observedArea`, `phenomenonTime`, `resultTime`, plus `observedProperty` |
| `coaty.sensorThings.Thing` | `description`, optional `properties` |

The object-type constants are in `Source/SensorThings/Sensor.swift:203-209`.
Registration occurs during `Container.resolve` through
`CoreType.registerSensorThingsTypes`. Capture fixtures must cover the nested
types used by Sensor (`UnitOfMeasurement`, `ObservedProperty`, polygon and
time-interval representations) and heterogeneous raw JSON `String` values, not just
the four top-level discriminators.

## Current test evidence and gaps

| Area | Existing evidence | Missing compatibility evidence |
|---|---|---|
| IO routing | No IO-focused test exists under `Tests/` | No Associate/IOV capture, cross-language producer/consumer test, raw-value test, external-route test, or IoState behavior test |
| SensorThings | `SensorThingsTests.advertise` exercises the four object types between two current Swift containers; `channel` exercises Channel; mocks also use Discover/Resolve | No golden reference payloads, JS/legacy Swift direction, Query/Retrieve capture, full field-boundary fixtures, unknown-field behavior, or semantic assertions for nested types |
| Reference agents | CoatyJS 2.4.0 has a reproducible Linux image; legacy Swift 2.4.0 has an immutable source pin | CoatyJS runner supports only `advertise`; legacy Swift requires a macOS/Xcode runner or macOS-produced captures |
| Capture tooling | Passive MQTT capture preserves topic, raw bytes, QoS, retain, duplicate flag, and order | No IO or SensorThings scenario currently invokes it; no approved fixtures exist for these capabilities |

Reference-agent feasibility is therefore:

- **CoatyJS 2.4.0:** feasible on Linux after extending the scenario runner with
  IO components/models and deterministic IDs. Use the public CoatyJS IO API;
  raw MQTT injection is insufficient evidence of consumer behavior.
- **Legacy Swift 2.4.0:** feasible only on macOS without modifying the oracle.
  Build a small Xcode runner at the pinned commit and export lossless captures
  plus application-level assertions. Linux CI can replay approved captures;
  release CI or a documented manual gate must run the live legacy directions.
- **Modern Swift:** feasible in the existing Podman test image. It should act
  as producer and consumer, and report decoded application-level results.

## Required capture scenarios

Use namespace `wire-compat-v1`, deterministic UUIDs, QoS/retain capture, and
application-level acknowledgements. Run every live scenario JS -> modern,
modern -> JS, legacy -> modern, and modern -> legacy unless explicitly noted.

1. **Associate generated route:** one source, one actor, nonzero update rate;
   assert exact ASC topic, field presence, generated IOV route, and both local
   IoState views.
2. **JSON IoValue:** publish scalar, object, array, `null`, integer boundary,
   floating-point value, Unicode string, and nested values after association;
   assert exact IOV topic and decoded meaning.
3. **Raw IoValue:** publish bytes including NUL and invalid UTF-8; compare raw
   bytes exactly and assert actor delivery without JSON decoding.
4. **External route:** associate on a deterministic non-Coaty topic, publish
   JSON and raw variants, and verify `isExternalRoute` plus routing behavior.
5. **Fan-out and transitions:** one source/two actors, disassociate one,
   reassociate to a new route, then disassociate all; assert subscriptions,
   delivery set, and ordered IoState transitions.
6. **Negative IO cases:** invalid context filter, mismatched value type/raw
   mode, IoValue before association, missing optional Associate fields,
   unknown fields, duplicate Associate, and late value after disassociation.
7. **SensorThings schema fixtures:** one fully populated and one minimal object
   of each of the four types, including nested Sensor fields, time intervals,
   polygon, heterogeneous metadata/result, empty collections, and Unicode.
8. **SensorThings standard patterns:** Advertise and Channel for all four
   types; Discover/Resolve and Query/Retrieve for Sensor and Thing; Observation
   production/consumption through the Sensor controllers.
9. **Forward compatibility:** unknown object property, unknown SensorThings
   object type, omitted optional fields, and reordered JSON keys. Preserve
   unknown data only where the reference implementations do so.
10. **Lifecycle/failure overlap:** broker reconnect while associated and
    source/router shutdown. Coordinate with T-020 so this is captured once.

For raw IOV, the capture must be authoritative: do not create a JSON golden
fixture by calling `IoValueEvent.encode`. For IoState, record an assertion log
alongside the wire capture and explicitly assert that no IoState publication
occurs.

## Keep / diverge / remove decision gates

Decide independently for Associate, generated routing, external routing, JSON
IoValue, raw IoValue, IoState API behavior, and each SensorThings object/event
surface. A single umbrella decision is not sufficiently precise.

### Keep

Choose **keep** only when all of the following are true:

- Both directions pass live CoatyJS tests and modern Swift decodes the approved
  legacy Swift captures.
- Modern -> legacy is demonstrated live on macOS, or explicitly blocks release
  until that runner is available.
- Exact topics, raw bytes where applicable, field presence, QoS/retain, and
  application-level semantics match.
- Reconnect/disassociation behavior does not leak subscriptions or deliver to
  the wrong actor.
- The capability has a maintained user or framework use case and its ongoing
  test cost is accepted.

### Intentional divergence

Choose **diverge** only for a documented defect, safety fix, platform
constraint, or deliberate API evolution where preserving legacy behavior is
more harmful than breaking it. The decision must include:

- exact observed reference behavior and capture IDs;
- modern behavior and affected directions;
- migration guidance and versioning impact;
- a regression test that locks in the new behavior;
- explicit approval in the compatibility matrix and roadmap.

Wire spelling, object-type strings, UUID/topic placement, or silent
normalization of field presence are not acceptable accidental divergences.

### Remove

Choose **remove** only when the capability is unused or unmaintainable, has no
required production consumer, and maintaining truthful compatibility would
cost more than its supported value. Removal requires:

- evidence from all reference scenarios (a current failure alone is not proof
  of dispensability);
- repository/API usage inventory and downstream-owner sign-off;
- deprecation and migration path, including replacement event/model APIs;
- a major-version boundary for public API or protocol removal;
- deletion or reclassification of fixtures so CI cannot imply support.

Until these gates are satisfied, mark the capability **not yet tested**, not
compatible, divergent, or removable.

## Evidence package for the final T-021 decision

For each scenario retain the reference version/commit, runner image digest or
macOS/Xcode version, scenario configuration, raw JSONL capture, normalized
comparison output, application assertion log, and modern test revision. The
final decision must link these artifacts, update the compatibility matrix and
roadmap, and identify the CI tier that prevents regression.
