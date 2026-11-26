---
status: proposed
---

# Configurable payload limits and participants with smaller limits

Proposed for [#1085](https://github.com/phynics/axoloty/issues/1085). This ADR
is a draft for the repository owner. It is not accepted and nothing here is
implemented. It amends the 2 KiB ceiling decision in
[`docs/wire-compatibility.md`](../wire-compatibility.md) for hosted runtimes,
and it defines how a sender treats a peer that accepts less than the sender
does. Implementation follows only after the owner accepts or amends it.

## Context

Every Axoloty payload is limited to 2,048 bytes, on the host and on the device.
The limit was chosen to keep parser, protocol-state, retained-action, and
transport storage finite on ESP32-class devices
([`wire-compatibility.md`](../wire-compatibility.md), "Decision: Axoloty 2 KiB
payload ceiling"). Coaty and CoatyJS define no such limit.

[Gnostic](https://github.com/phynics/Gnostic) is a hosted consumer with no
embedded participant, and the limit breaks it in normal use
([phynics/Gnostic#751](https://github.com/phynics/Gnostic/issues/751)):

- A Turn prompt is capped at 1,400 bytes, so that the value fits one
  1,800-byte budget plus its envelope. ACP clients add about 5 KB of context
  to each message, so every Turn fails
  ([phynics/Gnostic#747](https://github.com/phynics/Gnostic/issues/747)).
- Diagnostics snapshots fail once a Runtime has about nine Timelines
  ([phynics/Gnostic#752](https://github.com/phynics/Gnostic/issues/752)).
- Turn results and Workspace tool output are truncated at the bound.
- ACP content blocks such as images cannot fit at all
  ([phynics/Gnostic#731](https://github.com/phynics/Gnostic/issues/731)).

Gnostic runs the host runtime over `MQTTBinding` with the default capabilities,
so it uses `coaty/3` JSON. It sets `protocolMaximumPayloadBytes` to
`WireBufferConfig.maxPayloadSize` and cannot set it higher.

The firmware side has a related request.
[phynics/axoloty-embedded#154](https://github.com/phynics/axoloty-embedded/issues/154)
asks for 8,056-byte frames on ESP32-C6 while the node's own I/O values stay
below 512 bytes.

### Evidence labels

Every figure in this ADR carries one label.

- **source**: read from the code at `9a7733cb`, with a file and line.
- **derived**: arithmetic from stated assumptions or from source figures.
- **assumed**: a value nobody has checked for this ADR.
- **issue**: quoted from a linked issue; not reproducible here.

No code was run for this ADR.

### Where the ceiling is enforced today

The limit appears in two forms. Some sites **check** a payload against a
limit. Others **size storage** by the limit. Only the processor and its host
caller take the limit as a parameter. Every other site reads the global
constant (source).

| Site | Form | Limit used |
|---|---|---|
| `ProtocolProcessor` inbound and outbound (`ProtocolProcessor.swift:304`, `:690`, `:752`) | check | parameter `maximumPayloadBytes`; the host passes `protocolMaximumPayloadBytes` (`AxolotyRuntime.swift:128`) |
| `RuntimeCapacities` (`AxolotyRuntimeConfiguration.swift:77`) | check | rejects any value above `WireBufferConfig.maxPayloadSize` |
| `WireReader` JSON and CBOR initializers (`WireReader.swift:296`, `:336`, `:389`), `isValidJSONValue` (`:453`) | check | global constant |
| `ProtocolProcessor.validatePayload` (`:1355`), through `codec.reader` | check | global constant, a second time after the parameter check |
| `CBORReader` string default (`CBORReader.swift:72`), `WireValueReader` (`:195`, `:231`), `OwnedWireDataValidation` (`:13`), `ObjectPredicate` (`:470`) | check | global constant |
| External I/O admission (`AxolotyRuntime.swift:1136`), `validateRuntimeTransportMessage` (`ExternalIoRoute.swift:111`), last will (`AxolotyRuntimeTransport.swift:76`) | check | global constant |
| Workspace reader (`WireReader.swift:340`) | check | requires `capacity >= maxPayloadSize + 8`, whatever the frame length |
| `OwnedWireEvent.encodedBytes`, `RuntimeWirePayload.encode` (`RuntimeSupport.swift:72`, `RuntimeWirePayload.swift:196`), `OwnedWireData` (`:259`) | storage | allocates a zeroed array of the full limit, encodes, then trims |
| `RuntimeWirePayload.swift:309` | storage | stack `InlineArray<2048, UInt8>` |
| `Object<S>`, `DynamicObject` (`TypedObject.swift:148`, `:154`) | storage | `<2048, 24>` inline |
| I/O values and endpoints (`IoContracts.swift:257-340`, `IoEndpointDefinitions.swift:173`, `:176`) | storage | `<2048>` inline |
| Zenoh façade slots (`axoloty_zenoh.h:82`, `axoloty_zenoh_session.c:15-22`), `ZenohFrameStorage` (`:6`), `ZenohBindingConfiguration` (`:116`) | storage and check | 2,048 literal, on the host path too |
| `EmbeddedWireParserWorkspace` (`WireParserWorkspace.swift:56`) | storage | 2,056 |
| `ProtocolRetainedRouteStorage` (`ProtocolBufferConfig.swift:12`) | storage | 2,048 route bytes for the static sink; equal to the payload limit only by coincidence |

Copies on the host receive path are exact-length (source). MQTT copies the
payload with `Array(info.payload.readableBytesView)`
(`RuntimeMQTTClient.swift:193`). The host action sink retains borrowed actions
and reports `maximumPayloadBytes == Int.max` (`ProtocolActionSink.swift:82`),
and handlers receive exact-length `[UInt8]` copies (`ByteSlice.swift:199`).
Each nested JSON re-parse makes another padded copy of the nested length plus
eight bytes; CBOR makes none.

### Transports (source unless marked)

- **MQTT.** `mqtt-nio` 2.13.0 (`Package.resolved:14`), with no version passed
  to its configuration (`RuntimeMQTTClient.swift:76`), so MQTT 3.1.1, the
  library default. The binding checks no payload size on publish or on
  receive (`MQTTBinding.swift:269`, `:509-542`). MQTT 3.1.1 has no Maximum
  Packet Size negotiation. A broker that discards an oversized PUBLISH does so
  without telling the sender.
- **Brokers.** The in-process test broker has no size cap beyond the MQTT
  varint maximum (`MQTTPacket.swift:89-125`). The Mosquitto configurations in
  the repository set no `message_size_limit` or `max_packet_size`, so
  Mosquitto's defaults apply. Those defaults were not checked (assumed: no
  limit below the protocol maximum).
- **Zenoh host.** zenoh-c 1.10.0. The façade gives each subscription four
  fixed slots of 2,048 payload and 256 key bytes, and copies each sample into
  a slot. Larger samples are dropped and counted. The session sets no batch or
  fragmentation options, so zenoh-c defaults apply (assumed: large messages
  are fragmented by Zenoh and are not the binding limit).
- **No transport declares a payload limit.** `AxolotyRuntimeTransport` exposes
  capabilities and a wire profile only (`AxolotyRuntimeTransport.swift:89-199`).

### Constraints

- `WireBufferConfig.maxPayloadSize`, `maxTopicLength`, and
  `EmbeddedWireParserWorkspace` are frozen 1.0 symbols
  (`docs/api/core-1.0-public-symbols.json`). Firmware sizes buffers from them,
  for example `withUnsafeTemporaryAllocation(capacity: maxPayloadSize)` in the
  embedded smoke agent. Changing their value is a breaking change for those
  consumers, even though the signatures stay the same.
- `coaty/3` is sealed ([ADR 0002](./0002-seal-coaty-core-profile-3.md)). It
  gains no fields, so a `coaty/3` peer cannot declare anything about itself.
- `axoloty/1` accepts additive, ignorable envelope fields
  ([ADR 0015](./0015-axoloty-1-soft-state-presence.md),
  [ADR 0008](./0008-axoloty-1-cbor-extension-profile.md)). Shipped decoders
  ignore an unknown Advertise envelope field (ADR 0015, Claim 3).
- Host and static profiles share one wire and protocol path. A protocol rule
  lives in `AxolotyProtocol`, never only in a runtime.
- Portable state is finite. Saturation is structured and atomic.

## Decision

### 1. Separate the configured limit from the Core ceiling

**Options.**

- A. Raise `WireBufferConfig.maxPayloadSize`.
- **B. Keep `maxPayloadSize` at 2,048 as the default limit. Add a separate
  Core ceiling, and let each runtime configure its own limit up to it.**
- C. Remove the ceiling for hosted runtimes.

**Recommendation: B.** Add
`WireBufferConfig.maximumConfigurablePayloadSize` (value in decision 2).
`maxPayloadSize` keeps its value and is documented as the default limit and the
limit assumed for a peer that declares none. `RuntimeCapacities` accepts
`protocolMaximumPayloadBytes` up to the new ceiling. The default stays
`maxPayloadSize`.

**Reason.** A changes the value of a frozen constant that firmware uses to size
stack and static buffers. Every embedded consumer would grow, or fail its
budgets, without opting in. C removes the per-message bound that the
original decision exists to keep, and a hosted runtime still needs a bound
against a hostile peer. B is additive: a new constant and a wider accepted
range for an existing parameter.

**What would change this.** A major release could rename `maxPayloadSize` to
say what it now means (for example `defaultPayloadSize`). That is cosmetic
and does not need to block this work.

### 2. The ceiling value

**Options.** 8 KiB, 64 KiB, 256 KiB, 1 MiB.

**Recommendation: 262,144 bytes (256 KiB).**

**Reason.** Gnostic needs prompts of at least 64 KiB (issue). The limit is
measured on encoded bytes. JSON escaping of ordinary text adds a few percent,
but a string of control characters encodes each byte as six (`\u00XX`), so a
64 KiB value can encode to 384 KiB (derived). Gnostic validates the final
encoded value and rejects rather than truncates, so it can apply its own value
budget below the transport limit. 256 KiB covers the 64 KiB goal with room for
ordinary escaping, envelopes, and content blocks of moderate size.

The host keeps owned copies of payloads in bounded queues. The worst case is
the sum of the frame-holding capacities times the limit. With the default
`ingress = 64`, the ingress queue alone holds at most 128 KiB at 2,048 bytes
and 16 MiB at 256 KiB. At 1 MiB it holds 64 MiB (derived). 256 KiB keeps that
worst case acceptable for a desktop or server process. 8 KiB serves only the
firmware request.

**What would change this.** A consumer that needs single values above about
200 KiB should use transfer-level chunking. That is a Gnostic-side design
(phynics/Gnostic#751 options 1 and 2), not a larger ceiling.

### 3. The wire layer takes the limit as an input

**Options.**

- A. Keep the global checks in `AxolotyWire` and lift them to the ceiling.
- **B. Pass the configured limit through `WireCodec` to every reader,
  validator, and nested reader.**

**Recommendation: B.**

- `WireCodec` carries a `maximumPayloadBytes`, defaulting to `maxPayloadSize`.
  Readers made through a codec check that value. Existing initializers keep
  their signatures and default to `maxPayloadSize`, so current callers behave
  as today.
- A nested reader inherits its parent's limit.
- `ProtocolProcessor.validatePayload` uses the processor's own limit, so the
  processor stops checking twice against two different values.
- The workspace reader requires `capacity >= length + 8` and
  `length <= limit`. It no longer requires `maxPayloadSize + 8` for every
  frame. `EmbeddedWireParserWorkspace` keeps its size.
- `CBORReader`, `WireValueReader`, `OwnedWireDataValidation`, and
  `ObjectPredicate` take the limit from their caller or the codec.

**Reason.** A would let any caller that skips the processor parse 256 KiB on
an embedded build, and it keeps two sources of truth. B leaves one value per
runtime, chosen at composition time, which is what the processor already does.

**Prerequisite.** `isValidJSONValue` copies an unaligned value of up to
`maxPayloadSize` bytes into a 512-byte `SIMD64<UInt64>`
(`WireReader.swift:456-462`). In a release build an unaligned value above 512
bytes writes past that storage. Fix this before any limit grows, as its own
bug, with the aligned copy sized to the value or taken from the caller's
workspace.

### 4. Host encoding without a full-limit allocation

**Options.**

- A. Keep allocating the full limit and trimming.
- **B. Start with a small buffer and grow it on `bufferTooSmall`, up to the
  configured limit.**
- C. Two passes: compute the encoded size, then encode once.

**Recommendation: B**, for the host only (`Source/Runtime` and the host
helpers in `RuntimeSupport`). Start at 4 KiB and double. Portable writers keep
encoding into a caller-owned fixed buffer.

**Reason.** At 256 KiB, A zeroes a quarter megabyte for every publish, most of
which carry a few hundred bytes. C needs a size-counting writer for both JSON
and CBOR and doubles the encode work for every message. B costs at most a
logarithmic number of retries for a large message and nothing extra for a
small one. `RuntimeWirePayload.swift:309` must move off the stack
`InlineArray<2048, UInt8>`.

### 5. What stays at 2,048 bytes

These keep their fixed capacities, and nothing in this ADR enlarges them:

- `Object<S>` and `DynamicObject` (`<2048, 24>`). An application that decodes
  a larger object into these gets the existing structured capacity error. It
  can name a larger `BoundedObject<S, N, F>`, at the cost of inline storage of
  N bytes. Host applications that carry large values should keep them as raw
  bytes or decode them with their own codec.
- I/O values and endpoint definitions (`<2048>`). I/O values are small by
  design, and the external I/O admission check at `AxolotyRuntime.swift:1136`
  stays at `maxPayloadSize`.
- `EmbeddedWireParserWorkspace`, the static runtime's `payloadCapacity`
  ceiling, SensorThings, and `ProtocolRetainedRouteStorage` (route bytes, not
  payload).

**Reason.** These are value capacities, not frame capacities. Coupling them to
the frame limit is the problem this ADR removes. Enlarging an inline type
enlarges every instance of it, including on the stack.

### 6. Transports declare their limit

**Recommendation.**

- `AxolotyRuntimeTransport` gains `maximumPayloadBytes`, with a default
  implementation that returns `maxPayloadSize`. A transport written before
  this change is treated as a 2 KiB transport and keeps working.
- `RuntimeBuilder` rejects a composition whose
  `protocolMaximumPayloadBytes` exceeds the transport's value. This is a
  configuration error at build time, never a drop at run time.
- `MQTTBinding` reports the Core ceiling. It checks inbound payload length
  before copying and counts an oversized frame in `oversizedSamples`, which
  today counts only oversized topics (`MQTTBinding.swift:522`).
- `ZenohBinding` reports 2,048 until its façade changes (decision 9).

**Reason.** The runtime cannot detect a transport that silently drops large
frames, so the transport must state what it carries. A default implementation
keeps the requirement additive for the frozen `Axoloty` product.

**Limits of this decision.** A broker or router can impose a lower limit than
the client library. On MQTT 3.1.1, such a broker discards the message without
telling the sender. No Core check can see that. The operator must configure
the broker, and the live tests at the configured limit (acceptance, below)
are the evidence.

### 7. Host memory per message

**Options.**

- **A. Bound each message by the configured limit and each queue by its
  existing frame count. Document the product as the worst case.**
- B. Add a byte budget across all retained frames.

**Recommendation: A.** No new capacity. `RuntimeCapacities` documentation
states the worst case as the frame-holding capacities times
`protocolMaximumPayloadBytes`. A consumer that raises the limit lowers
`ingress`, `dispatch`, or `stream` if that product is too large.

**Reason.** A full ingress queue already fails the runtime with
`capacityExceeded` (`AxolotyRuntime.swift:398`). A byte budget would add a
second way to reach that failure, triggered by frame size instead of frame
rate. It would also need accounting across the ingress stream, the dispatch
queue, in-flight handlers, and event streams, which hold owned copies with
separate lifetimes. The count bounds are already finite, and A keeps the
behavior a consumer can predict from its configuration.

**Existing risk, not changed here.** `mqtt-nio` assembles a complete PUBLISH
before the binding sees it, so a peer can make the client buffer up to the
MQTT maximum (about 256 MiB) before any Axoloty check. This is true today at
2,048. Decision 6 rejects such a frame before the binding copies it, but it
cannot stop the library from reading it. Record the risk in
`SECURITY.md`. A fix needs a client-side packet limit in the library.

### 8. Participants with a smaller limit

Hosts with large limits and devices with small ones can share a namespace.
Today a receiver drops a frame above its limit and counts it, and the sender
does not learn of the drop.

**Which sends can be checked.** A sender knows its receiver only for a
response to a request it received: Resolve, Retrieve, Complete, and Return go
to the one requester whose correlation they answer. Every other event is
published to any interested subscriber: Advertise, Deadvertise, Channel,
Discover, Query, Update, Call, Associate, and I/O values. For those, the
sender does not know the receivers and cannot check their limits.

**Options.**

- **A. Declared peer limits on `axoloty/1`, an assumed peer limit
  everywhere else, and a check on responses only.**
- B. A namespace profile: every participant uses one configured limit,
  checked at startup.
- C. No declaration. Document drop-and-count and the sender's timeout.

**Recommendation: A.**

1. **Declaration.** An `axoloty/1` participant may add an optional
   `maxPayloadBytes` field to its Identity Advertise envelope, next to
   `leaseMs` and `ownerEpoch`:

   ```cddl
   advertise = {
     "object": object,
     ? "privateData": any,
     ? "leaseMs": uint,
     ? "ownerEpoch": uint,
     ? "maxPayloadBytes": uint,  ; axoloty/1 only, 1..262144, Identity only
   }
   ```

   It is emitted only when the participant's limit differs from 2,048. A value
   outside the range, a non-integer, or the field on a non-Identity Advertise is
   a structured `malformedPayload` rejection with no state change.
2. **Learning it.** The processor stores the declared value with the source's
   Identity record, as one `UInt32` per object slot. A participant is
   learned only from an Advertise that also carries `leaseMs` and
   `ownerEpoch`, because a changed limit must be learnable: a repeat Advertise
   without presence is rejected as a duplicate (ADR 0015, Claim 2), while a
   new owner epoch re-announces. The value is forgotten when the Identity is
   deadvertised, expires, or is discarded by a transport reset.
3. **Assumed limit.** A runtime gains an `assumedPeerPayloadBytes` setting,
   default 2,048, at most its own limit. It applies to every peer whose limit
   is unknown: a `coaty/3` peer, a peer that declares nothing, a peer whose
   Identity has not arrived yet or has expired, and every CoatyJS peer.
4. **Check.** A response is checked against
   `min(own limit, the requester's declared or assumed limit)`. A response
   above it is rejected before publication as `capacityExceeded`, the
   existing reason, and the host reports a distinct runtime observation that
   names the peer limit. Broadcast events are checked against the sender's own
   limit only.
5. **Requester source.** The processor does not record who sent an inbound
   request: its pending table holds only the local node's own requests
   (`ProtocolProcessor.swift:45-63`). The runtime that received the request
   passes the requester's source ID with the response operation, and the
   processor applies the rule. No new correlation table is added.

**Reason.** Responses are where a silent drop costs the most: a requester
waits for an answer that the network discarded, and the responder has no idea.
The check turns that into a local, typed failure. For broadcasts there is
nothing to check against, and a sender limited to the smallest known peer
would reduce every host to the weakest device. B does exactly that for the
whole namespace. C leaves the timeout. The assumed limit is what makes the rule
honest on `coaty/3`, where nothing can be declared. Gnostic, which has no small
peers, sets `assumedPeerPayloadBytes` equal to its own limit and gets today's
behavior at the larger size.

**Edge cases.**

| Case | Behavior |
|---|---|
| Response before the requester's Identity arrives | assumed limit |
| Requester restarts with a new limit | new owner epoch, re-announce, new value |
| Requester changes its limit without presence | not learned; the old value or the assumed limit stays until Deadvertise |
| Requester's Identity expires or a transport reset discards it | assumed limit |
| Declared limit above the responder's own limit | the responder's own limit |
| `coaty/3` peer, CoatyJS peer | assumed limit |
| Broadcast larger than some receiver's limit | sent; that receiver drops and counts |
| Request larger than the responder's limit | the responder drops and counts; the requester times out, as today |

The last row is not solved by this ADR. A requester can learn the limits of
known responders on `axoloty/1`, but a request has no single receiver.
Requesters that need certainty should keep requests small and put large data
in responses.

**What would change this.** Field use in mixed namespaces that shows
broadcasts, not responses, are the common failure. Then add an optional
sender policy that limits broadcasts to the smallest declared limit, as an
explicit opt-in.

### 9. Zenoh host façade

**Recommendation.** Keep the four-slot ring, and store an owned zenoh-c byte
handle in each slot instead of a fixed `payload[2048]` copy. The poll path
copies into an exact-length Swift array. The façade checks the configured
limit when the sample arrives. `ZenohFrameStorage` leaves the host receive
path.

**Reason.** Sizing fixed slots at the configured limit costs 4 sessions × 8
subscribers × 4 slots × the limit: 32 MiB at 256 KiB (derived). Owned
handles cost a pointer per slot and hold only the bytes that arrived.
`AxolotyZenoh` is experimental, so this changes no frozen API. Embedded
zenoh-pico sizing belongs to the firmware repository.

### 10. Static runtime frame and value capacity

The static runtime uses one `payloadCapacity` for its frame, its retained
actions, its endpoint values, and its pending values. Firmware that wants
larger frames with small values pays for every array
(phynics/axoloty-embedded#154, issue). Splitting it changes the generic
signature of the frozen `StaticRuntime<capacity, payloadCapacity>`.

**Recommendation.** Defer to a separate ADR with device evidence. This ADR
only raises the static ceiling: `StaticRuntimeDefinition` accepts a
`payloadCapacity` up to `maximumConfigurablePayloadSize` and stays at the
caller's choice. The split is not needed for hosted consumers.

## Compatibility

- **Default configuration.** A runtime that sets nothing behaves exactly as
  today: 2,048-byte limit, 2,048-byte assumed peer limit, no declaration
  emitted, identical bytes.
- **`coaty/3`.** No new field. A larger limit is an Axoloty configuration
  choice; CoatyJS imposes no limit, so a CoatyJS peer accepts larger frames
  from a configured Axoloty host. A peer limited to 2,048 drops them, as it
  would drop any oversized frame today.
- **`axoloty/1`.** One additive envelope field. Shipped decoders ignore it
  (ADR 0015, Claim 3).
- **Golden corpus.** New CBOR entries for an Identity Advertise with
  `maxPayloadBytes`, at each bound and one outside. Exact-limit and
  one-over tests at a widened limit, for JSON and CBOR, beside the unchanged
  2,048 fixtures.
- **`docs/wire-compatibility.md`.** The 2 KiB decision becomes: 2,048 is the
  default and the assumed peer limit; a hosted runtime may configure up to the
  Core ceiling; Axoloty still does not fragment.
- **Versioning.** Every change is additive: a new constant, a wider accepted
  range, a defaulted transport requirement, a new setting, a new envelope
  field, and a new runtime observation. Under
  [`versioning.md`](../versioning.md) this fits a minor release. The API
  baseline is regenerated for the new symbols.

## Implementation plan

Each slice ends in a verifiable state. Gnostic is unblocked after slice 4.

| Slice | Content | Size | Main risk |
|---|---|---|---|
| 1 | Fix the `isValidJSONValue` unaligned overflow | small | none; a bug fix with a reproduction |
| 2 | Wire limit through `WireCodec`, readers, validators, nested readers, workspace rule | medium | many call sites; tests that lock 2,048 must keep passing at the default |
| 3 | `RuntimeCapacities` ceiling, host checks on the configured limit, growing encoder, `assumedPeerPayloadBytes` setting | medium | replacing every global check in `Source/Runtime` without missing one; the table in Context is the checklist |
| 4 | Transport `maximumPayloadBytes`, builder check, `MQTTBinding` admission check, live Mosquitto test at the limit | medium | broker defaults; the live test is the evidence |
| 5 | `maxPayloadBytes` declaration, processor storage, response check, requester source on responses, corpus, host and static trace parity | large | frozen-enum constraints on the observation (question 4); parity of the new rule across both runtimes |
| 6 | Zenoh façade owned handles | large | C façade lifetime of zenoh-c handles across poll |
| 7 | Static frame and value split | large | separate ADR; frozen generic signature |

Slices 1 to 4 need no peer-limit work. Slice 5 can follow without blocking
Gnostic. Slices 6 and 7 are independent.

## Acceptance of #1085 and where each item is proven

| #1085 acceptance item | Where |
|---|---|
| A hosted runtime above 2,048 exchanges a payload at its exact limit, byte for byte, JSON and CBOR | Core: host runtime tests over the test broker; live Mosquitto test (slice 4) |
| One byte over is rejected on send and receive with a structured error | Core: runtime and binding tests (slices 3, 4) |
| Default host unchanged at 2,048 and 2,049 | Core: existing boundary tests untouched |
| Host-to-embedded behavior for a smaller participant | Core: processor and trace parity tests (slice 5); device evidence in `phynics/axoloty-embedded` |
| Memory per message bounded by the configured limit | Core: encoder and admission tests; worst case documented on `RuntimeCapacities` |

## Questions for the owner

1. Ceiling: 256 KiB, or another value?
2. Name: `maximumConfigurablePayloadSize`, or another?
3. Should the peer-limit work (decision 8) be in this change, or a follow-up
   after Gnostic is unblocked?
4. The peer-limit rejection reuses `capacityExceeded`. Reporting the peer limit
   needs a new runtime observation. If that is a new case on a frozen public
   enum, it is a major-release change, as ADR 0015 question 4 found. Choose:
   an additive observation type (recommended), or the next major.
5. `assumedPeerPayloadBytes` defaults to 2,048. Should a runtime with a larger
   limit default it to its own limit instead? That suits Gnostic but hides the
   embedded case.
6. Decision 7: is documenting the worst case enough, or does the owner want a
   byte budget now?
7. Should Zenoh (decision 9) be part of this change, or stay at 2,048 until a
   consumer needs larger frames over Zenoh?

## Consequences

- Hosted consumers can carry values up to the configured limit in one message.
- Embedded builds are unchanged unless a firmware raises its own capacity.
- Each runtime has one payload limit, used by every check on its path.
- A response that a requester cannot accept fails at the responder instead of
  timing out at the requester.
- Broadcasts larger than a small peer's limit still drop at that peer.
- The host worst-case memory grows with the configured limit. It is bounded and
  documented, and the consumer controls it.

## Rejected alternatives

- **Fragmentation in Axoloty.** It needs reassembly state per sender, ordering
  across routes, and expiry, on every profile and both runtimes. Transfer-level
  chunking in the consumer (phynics/Gnostic#751) covers values beyond the
  ceiling without changing the protocol.
- **Changing the value of `maxPayloadSize`.** See decision 1.
- **MQTT 5 Maximum Packet Size.** It would tell the client what the broker
  accepts, but Axoloty uses MQTT 3.1.1 and the decision concerns peers, not
  the broker.
- **Declaring the limit inside the Identity object.** Protocol metadata inside
  an application object, visible to handlers and open to schema collisions, as
  in ADR 0015 decision 1.
- **Limiting every send to the smallest known peer.** See decision 8.
- **A namespace-wide profile (decision 8, B).** It forces every participant to
  one limit.
