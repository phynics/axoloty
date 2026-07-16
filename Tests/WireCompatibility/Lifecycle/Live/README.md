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

Three of the eleven catalog scenarios are executable against the pinned
CoatyJS 2.4.0 reference agent, all verified end-to-end (not merely
syntax-checked) on a macOS host with a local Mosquitto broker and `node`/`npm`
running `@coaty/core` directly, ahead of writing the container-based scripts:

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

The remaining six catalog entries (`offline-queueing`, `reconnect-resubscribe`,
`broker-restart`, `clean-session`, `duplicate-reply`, `late-reply`) are
emitted as `unsupported`, with their reference-fixture/harness limitation in
their manifest: this harness has no Axoloty lifecycle test subject, and the
network-manipulation and Call/Return request/reply machinery those scenarios
need were not built in this pass. In particular, none of these results claim
an Axoloty lifecycle capture or bidirectional cross-implementation proof.

To execute only the currently available evidence-producing scenarios:

```sh
WIRE_LIFECYCLE_SCENARIOS="unexpected-disconnect-last-will qos-0 graceful-deadvertise" \
  Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh
```
