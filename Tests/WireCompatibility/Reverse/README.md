# Axoloty → CoatyJS live compatibility

This scenario starts pinned CoatyJS 2.4.0 as a consumer, publishes a fixed
Advertise event from Axoloty, and requires CoatyJS to decode and acknowledge
all protocol-significant object fields.

Run from the repository root:

```sh
Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh
```

The Swift Testing case is environment-gated and disabled during the normal
test suite.

## Axoloty → CoatyJS core matrix

`run-axoloty-core.sh` is a live-gated, one-direction matrix: a current Axoloty
test producer publishes Deadvertise, Channel, Discover/Resolve,
Query/Retrieve, Update/Complete, and Call/Return through an isolated MQTT
broker. A pinned CoatyJS 2.4.0 consumer decodes the application data and, for
request/response scenarios, publishes the corresponding response. Each
scenario retains a passive raw MQTT capture in `.testing/wire/` and uses fixed
producer, responder, object, and namespace identifiers.

Run it only in the supported container environment:

```sh
Tests/WireCompatibility/Reverse/run-axoloty-core.sh
```

Use `WIRE_SCENARIOS` to select a whitespace-separated subset. This harness
does not claim coverage for any other interoperability direction.

## CoatyJS → Axoloty Advertise (JS → modern)

`run-coatyjs-to-axoloty-advertise.sh` is the mirror direction: pinned CoatyJS
2.4.0 is the producer and Axoloty (modern Swift, `AxolotyAdvertiseConsumerTests`)
is the consumer under test. The runner starts Axoloty detached so it can
subscribe first, waits for its `"state":"ready"` log line (emitted only after
`observeAdvertiseStream` has acquired the MQTT topic), then runs the existing
`Tests/WireCompatibility/Live/coatyjs-advertise-runner.js` producer to
completion, and finally requires Axoloty's `"state":"ack"` line, which the
Swift Testing case only prints after asserting the decoded
`AdvertiseEventSnapshot`'s `coreType`, `objectType`, `objectId`, and `name`
against the fixture CoatyJS put on the wire.

Run it only in the supported container environment:

```sh
Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh
```

This was verified end-to-end on a macOS host outside the container harness
(local Mosquitto plus `node`/`npm` running the pinned `@coaty/core` reference
agent directly) before this script was written, so the container-based script
itself is currently syntax-checked (`bash -n`) and contract-tested rather than
executed, in environments without `podman`/`docker`.

Before this addition, `Tests/WireCompatibility/Live/run-coatyjs-core.sh`
covering the JS → modern direction only validated the CoatyJS-to-CoatyJS
reference wire protocol with no Axoloty consumer in the loop; this is the
first live JS → modern coverage with a real Axoloty subject.
