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

Today, only the pinned CoatyJS 2.4.0 unexpected-disconnect scenario is
executable: it waits for the subject identity advertisement, sends `SIGKILL`,
and verifies the broker-issued deadvertise last will at QoS 0 without retain.
The other catalog entries are emitted as `unsupported`, with their reference
fixture limitation in their manifest. In particular, these results do not claim
an Axoloty lifecycle capture or bidirectional cross-implementation proof.

To execute only the available evidence-producing scenario:

```sh
WIRE_LIFECYCLE_SCENARIOS=unexpected-disconnect-last-will \
  Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh
```
