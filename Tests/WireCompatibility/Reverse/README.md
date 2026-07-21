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

## CoatyJS → Axoloty (JS → modern)

`run-coatyjs-to-axoloty-advertise.sh` covers Advertise. The parameterized
`run-coatyjs-to-axoloty-core.sh` covers Deadvertise, Channel, Discover/Resolve,
Query/Retrieve, Update/Complete, and Call/Return. Pinned CoatyJS 2.4.0 is the
producer/requester and Axoloty is the consumer/responder under test. Each
runner starts Axoloty detached, waits for a file written only after the Swift
side has acquired its MQTT subscription, then starts CoatyJS. The Swift
Testing cases assert decoded request/event fields. Request/response cases also
publish a response with the received correlation ID, while the CoatyJS
requester asserts the response fields.

Run it only in the supported container environment:

```sh
Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh
WIRE_SCENARIOS="deadvertise channel discover-resolve query-retrieve update-complete call-return" \
  Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-core.sh
```

The runners use the repository's shared SwiftPM build cache and a mounted
readiness file rather than polling Swift Testing output. This prevents cold
worktree builds and test-runtime output buffering from starting CoatyJS after
the Axoloty receive deadline. The scenarios were verified end-to-end with
Podman on Linux.

`Tests/WireCompatibility/Live/run-coatyjs-core.sh` remains the reference-agent
matrix; the Reverse runners above are the cross-implementation JS → modern
evidence with a real Axoloty consumer/responder in the loop.
