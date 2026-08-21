# Embedded static IO endpoints

The ESP32-C6 profile can host a fixed startup configuration of IO sources and
actors through `StaticIoEndpoints`. It is an endpoint data plane, not an IO
router: a host router remains responsible for selecting endpoints and sending
the existing `Associate` messages.

Each descriptor contains a `UUID16`, an application value-type contract, raw
or JSON mode, and an optional configured update rate. The registry has a fixed
descriptor capacity (`ProtocolBufferConfig.maxFamilyEntries`); it has no dynamic
registration, discovery, source-to-actor matching, rules, controller APIs, or
unbounded subscriptions.

On an Associate, a local source retains one assigned route and an association
count. It may publish only while that count is positive. A local actor retains
its assigned route and receives bare values synchronously; disassociation
clears the route, so subsequent values are rejected before its handler runs.
The registry reports association status, route length, and negotiated update
rate without exposing mutable transport buffers.

Raw endpoints receive and publish their exact bare bytes. JSON endpoints
receive and publish one validated, bare JSON value; the runtime does not wrap
it in an `IoValueEventData` object. When both endpoints in an Associate are
local, their value-type contracts and modes must match. Unknown IDs, empty or
oversized routes, negative rates, malformed JSON, incompatible modes, and a
second source route are rejected before dispatch.

Input is bounded by `WireBufferConfig.maxTopicLength` and
`WireBufferConfig.maxPayloadSize`. The ESP-MQTT transport rejects fragmented
PUBLISH deliveries for this profile; it does not assemble partial input. Actor
handlers run synchronously with a borrowed payload and must not retain it.

The runtime exposes, but does **not** enforce, the negotiated update rate.
Rate limiting belongs to the application/sensor scheduler because it owns
sampling policy and can decide whether a negotiated limit is a maximum,
minimum, or advisory cadence. TLS, QoS 1/2, persistence, raw MQTT APIs,
`IoRouter`, rule evaluation, and dynamic endpoint registration remain
unavailable on embedded targets.
