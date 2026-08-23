# Embedded static IO processing

The ESP32-C6 profile uses the fixed-inline `ProtocolProcessor<16>` for
association state and `ProtocolSubscriptionRegistry<16>` for synchronous
delivery. There is no separate endpoint registry or router. A host transport
remains responsible for selecting topics and sending the existing `Associate`
messages.

The processor retains bounded source/actor routes, permits one actor to have
multiple source associations, and clears actor state only after its final
source detaches. Handlers are noncapturing thin functions with caller-owned
numeric contexts; borrowed payloads are valid only during the synchronous
dispatch call.

Route classification is supplied by the binding. The pinned external route is
`external/wire-compat-v1/io-external-1`; unrelated routes are ignored and
contradictory optional flags are rejected before state mutation.

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
