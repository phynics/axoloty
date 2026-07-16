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
