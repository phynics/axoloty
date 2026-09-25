# Live wire-compatibility scenarios

This directory contains executable live-wire slices that run pinned reference
implementations against a real MQTT broker and validate captured behavior.
Some slices exercise Axoloty/CoatyJS interoperability; the core scenarios use
CoatyJS at both endpoints as reference-wire coverage. Generated captures are
written to the ignored `.testing/wire/` directory and retained when verification
fails.

## Host MQTT binding network suite

Run the focused host-adapter suite from the repository root:

```sh
Tests/Support/WireCompatibility/Live/run-mqtt-binding-network.sh
```

The runner starts a run-scoped Mosquitto broker and an independent CoatyJS
capture probe. It runs `MQTTBindingNetworkTests` against the fresh broker,
then restarts Mosquitto and verifies a new binding session installs profile
subscriptions and receives a CoatyJS Advertise. Application JSONL, peer and
broker logs, and the fresh MQTT capture remain under `WIRE_OUTPUT_DIR` (default
`.testing/wire/mqtt-binding`). Offline MQTTBinding fixtures and the retained
fresh-broker capture are separate evidence; this runner does not update the
canonical test manifest.

## CoatyJS → wire capture: Advertise

Run from the repository root:

```sh
Tests/Support/WireCompatibility/Live/run-coatyjs-advertise.sh
```

The script builds the project development image and pinned CoatyJS 2.4.0
reference image, then starts Mosquitto, the passive MQTT probe, and the
reference agent on an isolated Podman network. The live runner waits for the
CoatyJS communication manager's asynchronous `start` operation before it
publishes; the status line is therefore also an application-level connection
acknowledgement. Verification requires:

- the deterministic fixture object to be present in the decoded JSON;
- both the core-type and object-type Advertise topic variants;
- Coaty protocol version 3 and the configured namespace;
- QoS 0 with the retain flag unset.

Set `WIRE_OUTPUT_DIR` to retain captures elsewhere. `DEV_IMAGE` and `JS_IMAGE`
may be set to reuse prebuilt images with different local names.

The Node wire CLI is built by `make wire-tool`; the scenario has no host Python
dependency.

## CoatyJS reference-wire core scenarios

Run the remaining implemented CoatyJS core scenarios from the repository root:

```sh
Tests/Support/WireCompatibility/Live/run-coatyjs-core.sh
```

This runs Deadvertise, Channel, Discover/Resolve, Query/Retrieve,
Update/Complete, and Call/Return sequentially against one isolated broker.
Both endpoints are CoatyJS reference agents, so these scenarios validate the
reference wire protocol rather than Axoloty/CoatyJS interoperability or
Axoloty feature parity. Each scenario gets a fresh passive capture and an
independent semantic verifier. The Discover/Resolve scenario uses two reference
agents and requires both the response payload and its MQTT topic correlation ID
to match the request. IDs, channel data, private data, and object data are
deterministic; Coaty-generated request correlation IDs are checked relationally
rather than hard-coded.

All request/response scenarios validate the request correlation ID is nonempty
and that the response uses the exact same ID. Query, Update, and Call payloads
also include deterministic request and response markers so a response from an
unrelated publication cannot satisfy the verifier.
