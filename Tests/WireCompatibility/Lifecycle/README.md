# Lifecycle and failure compatibility

`LifecycleCompatibilityScenarioTests.swift` is the executable contract for
the lifecycle interoperability runner. It defines broker/participant actions
and the wire observations required for a pass. The catalog itself is tested so
that required scenarios cannot silently disappear while the live runner is
being built.

## Runner protocol

The runner executes every catalog scenario three times, substituting the
scenario subject with modern Swift, CoatySwift 2.4.0, and the pinned CoatyJS
reference agent. A passive MQTT capture records topic, payload, QoS, retain
flag, ordering, and broker session state. Dynamic identifiers and timestamps
may be normalized; delivery count, ordering, QoS, session state, and lifecycle
event kind must not be normalized.

The subject and observer must be different implementations where an observer
is required. Rotate observers so the matrix covers modern Swift ↔ legacy Swift
and modern Swift ↔ CoatyJS in both directions.

## Deterministic controls

- Network disconnect means isolating the subject while leaving its process
  alive; graceful process termination is a different action.
- Broker restart waits for the broker port to close before starting it again.
- Reconnect assertions begin only after the subject reports an MQTT connection.
- Late replies are sent after the request timeout has observably fired.
- Duplicate replies reuse the same correlation identifier and payload.
- Each scenario gets a fresh namespace and broker state unless it explicitly
  tests persisted session behavior.

## Pass criteria

All declared observations must be present and no unexpected lifecycle event may
occur. Offline publications must retain order and appear once. Reconnection and
broker restart must restore subscriptions. Graceful shutdown must publish a
deadvertise event without triggering the last will; network loss must trigger
the last will. A clean session reconnect must report no previous session and
restore subscriptions. Only the first timely reply is accepted. QoS 0, 1, and
2 probes must be observed at the declared level.

`Live/run-lifecycle-matrix.sh` turns this catalog into live-gated evidence
manifests. A manifest is `executed` only after application and MQTT-capture
evidence have both been retained. A manifest may instead be `unsupported` when
the pinned reference fixture or this harness cannot expose the deterministic
control a scenario needs; that is a documented limitation, never a passing
cross-implementation result.

Five of the eleven catalog scenarios are executable end-to-end today:

- `unexpected-disconnect-last-will`, `qos-0`, `graceful-deadvertise`: CoatyJS
  2.4.0 is the live subject; Axoloty is recorded as an unavailable subject for
  these three, not as cross-implementation proof.
- `duplicate-reply`, `late-reply`: **Axoloty (modern Swift) is the live
  subject** -- the Call/Return initiator -- against pinned CoatyJS 2.4.0 as
  the responder. This is the first pair of lifecycle scenarios with Axoloty as
  a genuine subject rather than an unavailable one.

The remaining four (`offline-queueing`, `reconnect-resubscribe`,
`broker-restart`, `clean-session`) are `unsupported`: they need a network-
manipulation harness (severing/restoring the TCP connection between Axoloty
and the broker, or a controllable broker restart) that was not built in this
pass. See `Live/README.md` for the full disposition of every catalog entry,
including the verified reason `qos-1`/`qos-2` are `unsupported`: pinned
`@coaty/core@2.4.0` hardcodes QoS 0 for every publish regardless of
configuration.
