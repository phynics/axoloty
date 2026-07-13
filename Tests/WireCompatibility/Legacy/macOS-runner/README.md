# Pinned legacy CoatySwift macOS runner

This SwiftPM executable runs the unmodified CoatySwift 2.4.0 implementation
at its exact peeled tag commit, `20a97b29832758fb771ac79fd5f7ae36cff69403`.
`Package.resolved` also preserves the dependency graph shipped by that commit.
It is intentionally macOS-only because the legacy MQTT stack contains Apple
Objective-C sources.

Prepare it before starting a capture, so dependency fetching and compilation
cannot consume the capture probe's timeout:

```sh
Tests/WireCompatibility/Legacy/macOS-runner/prepare.sh
```

With Mosquitto listening on `127.0.0.1:1883`, generate the initial Advertise
capture from the repository root:

```sh
rm -rf /tmp/coatyswift-2.4.0-advertise
OUTPUT_DIR=/tmp/coatyswift-2.4.0-advertise \
LEGACY_SCENARIO_COMMAND="$PWD/Tests/WireCompatibility/Legacy/macOS-runner/run.sh" \
SCENARIO=advertise EXPECTED_PUBLICATIONS=2 \
Tests/WireCompatibility/Legacy/run_capture_on_macos.sh
```

Two publications are expected: CoatySwift's automatic Identity advertisement
on connection followed by the deterministic reference-object advertisement.
Both are protocol evidence and should remain in the lossless capture.
