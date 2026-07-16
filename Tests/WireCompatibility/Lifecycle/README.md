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
the pinned reference fixture cannot expose deterministic controls; that is a
documented limitation, never a passing cross-implementation result. The
currently executable CoatyJS last-will direction does not stand in for an
Axoloty capture or proof in the reverse direction.
