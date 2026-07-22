# Live lifecycle compatibility tests

Run the live lifecycle matrix from the repository root:

```sh
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh
```

Every scenario gets a retained `manifest.json` and `verifier.log` under
`.testing/wire/lifecycle/<scenario>/`. An executed result must contain both a
JSONL application log and a lossless MQTT capture. The harness has explicit
deadlines for broker subscription, application readiness, identity advertisement,
and last-will observation; polling is only a transport mechanism, never the
assertion.

Nine of the eleven catalog scenarios are executable, all verified end-to-end
(not merely syntax-checked) on a macOS host with a local Mosquitto broker and
`node`/`npm` running `@coaty/core` directly, ahead of writing container-based
scripts. This host has no `docker`/`podman`; `run-lifecycle-call-return.sh`
(below) runs mosquitto/node/`swift test` as native processes on purpose,
matching the precedent the other three scripts set before they were
containerized.

CoatyJS 2.4.0 is the live subject (Axoloty is recorded as an unavailable
subject, not cross-implementation proof) for:

- `unexpected-disconnect-last-will` (`run-coatyjs-last-will.sh`): waits for
  the subject identity advertisement, sends `SIGKILL`, and verifies the
  broker-issued deadvertise last will at QoS 0 without retain.
- `qos-0` (`run-coatyjs-qos-scenario.sh qos-0` via `coatyjs-qos-runner.js`):
  publishes a deterministic object and verifies it is observed at QoS 0.
- `graceful-deadvertise` (`run-coatyjs-qos-scenario.sh graceful-deadvertise`):
  calls `container.shutdown()` itself (not `SIGKILL`) and verifies the
  client-issued Deadvertise follows its Advertise — the counterpart to the
  broker-issued last will above.

`qos-1` and `qos-2` are NOT executable and are recorded as `unsupported` for a
specific, verified reason: pinned `@coaty/core@2.4.0`'s `MqttBinding` hardcodes
QoS 0 for every publish in `onJoin` (`this._qos = 0`, unconditionally) and
never reads a QoS option back out of communication configuration, despite a
stale doc comment implying otherwise. A live attempt at `qos-1` here captured
a wire `PUBLISH` with `qos: 0`. There is no other live QoS producer in this
harness to fall back to.

**Axoloty (modern Swift) is the live subject** for two scenarios —
`run-lifecycle-call-return.sh` (via `AxolotyLifecycleSubjectTests.swift` in
`Tests/WireCompatibility/Lifecycle/`, and CoatyJS's
`Tests/WireCompatibility/Reverse/coatyjs-core-consumer.js` acting as a
deliberately misbehaving Call responder):

- `duplicate-reply`: Axoloty calls `wire-fixture-operation`; CoatyJS's
  responder sends two genuine wire `Return` publishes for the same
  correlationId, "original" then "duplicate" 300ms later (nothing in
  `@coaty/core` 2.4.0's `CallEvent.returnEvent` prevents a responder from
  doing this — confirmed by reading `call-return.js` and
  `communication-manager.js` before relying on it). Axoloty's `EventHub` does
  not deduplicate `Return` events by correlationId either, so the "accept
  only the first" behavior asserted here is real application-level caller
  logic, not a library guarantee — documented as such, not silently assumed.
- `late-reply`: Axoloty calls with a 2s response deadline; CoatyJS's responder
  deliberately withholds its `Return` for 4s. The independent MQTT capture
  proves the late `Return` genuinely reached the broker only after Axoloty's
  `CM+Publish.swift` `responseStream` had already released (unsubscribed) the
  correlated response topic on timeout — the late reply is provably
  unobservable by Axoloty, not merely unobserved in this one run.

Both are verified against a cross-referenced independent MQTT capture and the
Axoloty application log by the lifecycle Swift test suite, matching the
evidentiary rigor of the CoatyJS-subject scenarios above.

**Axoloty is also the live subject** for the four network-failure scenarios,
run by `run-lifecycle-network.sh` (via the same
`AxolotyLifecycleSubjectTests.swift`):

- `offline-queueing`, `reconnect-resubscribe`, `clean-session`: the subject's
  MQTT connection runs through `axoloty-wire proxy`, a controllable local TCP proxy
  the orchestrating script commands to genuinely sever and restore, while the
  passive capture probe stays connected to the broker directly. For
  `offline-queueing` the capture proves both labeled publications queued
  while offline arrive in order exactly once after restore; for the other two
  the subject must decode an Advertise probe that pinned CoatyJS 2.4.0
  publishes only after the subject reported its reconnect, proving genuine
  re-subscription (Axoloty always connects with `cleanSession: true`, so no
  broker session state could carry the old subscription over). For
  `clean-session` the proxy additionally decodes every MQTT CONNACK on the
  subject's connection and the verifier requires at least two handshakes all
  reporting `sessionPresent=false`.
- `broker-restart`: no proxy — the Mosquitto process itself is stopped and
  restarted, and the subject must reconnect and decode the post-restart
  CoatyJS probe. This scenario initially failed and exposed a real defect
  (fixed alongside this harness): `MQTTNIOClient`'s failed connect attempts
  never rescheduled auto-reconnect, because only established-then-closed
  connections fire mqtt-nio's close listener, so one refused attempt against
  a not-yet-listening broker permanently ended reconnection.

All four are verified by the lifecycle Swift test suite against the subject's
timestamped application log, the independent MQTT capture, and (for
clean-session) the proxy's CONNACK log.

`qos-1` and `qos-2` remain the only non-executable catalog entries; see the
verified reason above.

The Axoloty-subject scenarios can also be run directly (native, no container
runtime):

```sh
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-call-return.sh duplicate-reply
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-call-return.sh late-reply
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh offline-queueing
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh reconnect-resubscribe
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh broker-restart
Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh clean-session
```
