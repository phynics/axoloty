# Pinned legacy CoatySwift macOS runner

This SwiftPM executable runs the unmodified CoatySwift 2.4.0 implementation
at its exact peeled tag commit, `20a97b29832758fb771ac79fd5f7ae36cff69403`.
`Package.resolved` preserves the dependency graph used with that source revision.
It is intentionally macOS-only because the legacy MQTT stack contains Apple
Objective-C sources.

Prepare it before starting a capture, so dependency fetching and compilation
cannot consume the capture probe's timeout:

```sh
Tests/WireCompatibility/Legacy/macOS-runner/prepare.sh
```

With Mosquitto listening on `127.0.0.1:1883`, generate all three captures from
the repository root. Each command creates a lossless JSONL capture and its
provenance manifest in a fresh directory; the orchestrator derives the exact
publication count for the selected scenario, so do not override
`EXPECTED_PUBLICATIONS` unless diagnosing a capture.
Before it invokes the legacy runner, the orchestrator waits for the probe's
broker-acknowledged `coaty/#` subscription (up to `CAPTURE_READY_TIMEOUT`,
defaulting to 10 seconds). This preserves the automatic Identity publications
as capture evidence instead of relying on process startup timing.

```sh
rm -rf /tmp/coatyswift-2.4.0-advertise
OUTPUT_DIR=/tmp/coatyswift-2.4.0-advertise \
LEGACY_SCENARIO_COMMAND="$PWD/Tests/WireCompatibility/Legacy/macOS-runner/run.sh" \
SCENARIO=advertise \
Tests/WireCompatibility/Legacy/run_capture_on_macos.sh

rm -rf /tmp/coatyswift-2.4.0-deadvertise
OUTPUT_DIR=/tmp/coatyswift-2.4.0-deadvertise \
LEGACY_SCENARIO_COMMAND="$PWD/Tests/WireCompatibility/Legacy/macOS-runner/run.sh" \
SCENARIO=deadvertise \
Tests/WireCompatibility/Legacy/run_capture_on_macos.sh

rm -rf /tmp/coatyswift-2.4.0-discover-resolve
OUTPUT_DIR=/tmp/coatyswift-2.4.0-discover-resolve \
LEGACY_SCENARIO_COMMAND="$PWD/Tests/WireCompatibility/Legacy/macOS-runner/run.sh" \
SCENARIO=discover-resolve \
Tests/WireCompatibility/Legacy/run_capture_on_macos.sh
```

The capture counts are two for Advertise (automatic Identity plus the reference
object), two for Deadvertise (automatic Identity plus the reference object ID),
and four for Discover/Resolve (both deterministic identities, then the request
and its correlated response). The runner pins namespace `wire-compat-v1`,
requester identity `00000000-0000-4000-8000-000000000201`, responder identity
`00000000-0000-4000-9000-000000000202`, reference object
`00000000-0000-4000-8000-000000000101`, and private Resolve data
`{"reference":"coatyswift-2.4.0"}`. All observed messages are protocol
evidence and should remain in the lossless capture.

For Discover/Resolve, the requester registers its Identity observer before
either manager starts and waits until it receives the responder's automatic
Identity advertisement. That event proves the broker has activated the
requester subscription, so the deterministic Discover is not released on a
timing guess.

## Consumer scenarios (Modern → legacy)

The runner also supports consumer/responder scenarios where Axoloty (modern
Swift) produces events and the legacy CoatySwift 2.4.0 runner subscribes,
decodes, and reports the observed semantic fields. These are orchestrated by
`Tests/WireCompatibility/Legacy/run-modern-to-legacy.sh` and require a macOS
host with Xcode (the same platform constraint as the producer scenarios):

| Scenario | Runner scenario | Legacy role |
|---|---|---|
| Advertise | `consume-advertise` | Subscribe to Advertise, decode object |
| Deadvertise | `consume-deadvertise` | Subscribe to Deadvertise, decode object IDs |
| Channel | `consume-channel` | Subscribe to Channel, decode message |
| Discover/Resolve | `respond-discover` | Subscribe to Discover, publish Resolve |
| Query/Retrieve | `respond-query` | Subscribe to Query, publish Retrieve |
| Call/Return | `respond-call` | Subscribe to Call, publish Return |

Update/Complete does not yet have a consumer scenario; it can be added when
a concrete interoperability question requires it.

The requester and responder identities differ starting at their 17th hex
digit (`8000` vs. `9000`), not only in their trailing digits, because
CoatySwift derives each client's MQTT ClientID from exactly the first 18 hex
digits of its identity UUID (dashes stripped); two clients whose UUIDs only
differ later collide on ClientID and get disconnected by the broker every
time the other one (re)connects. See `../README.md` for this and the other
real bug (a blocked main run loop silently dropping every publication) that
generating these captures surfaced.
