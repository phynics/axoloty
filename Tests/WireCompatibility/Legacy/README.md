# Legacy CoatySwift capture and replay

This directory deliberately separates **reference generation** from
**portable validation**. CoatySwift 2.4.0 uses Apple/Objective-C dependencies
and is not executed on Linux. A macOS host runs the pinned legacy implementation
and produces a lossless JSONL capture plus a provenance manifest. Linux CI can
then validate and replay those immutable bytes against Axoloty.

## macOS reference generation

The scenario driver is a separately built executable from the pinned legacy
checkout. It must reject a source tree whose HEAD is not
`20a97b29832758fb771ac79fd5f7ae36cff69403`, connect to the supplied broker,
and implement the command-line contract documented in
`run_capture_on_macos.sh`. The orchestrator refuses to run off Darwin and
refuses to overwrite an existing artifact.

The pinned runner supports `advertise`, `deadvertise`, and `discover-resolve`.
Use `Tests/WireCompatibility/Legacy/macOS-runner/prepare.sh` first, then invoke
`run_capture_on_macos.sh` once per scenario with a new `OUTPUT_DIR` and
`LEGACY_SCENARIO_COMMAND` set to the pinned runner's `run.sh`. It derives the
expected lossless record count (2, 2, and 4 respectively); do not substitute
placeholder JSONL or manifests for a macOS-produced capture. See the
[macOS runner instructions](macOS-runner/README.md) for the exact commands.

Review both artifacts before committing them. The manifest binds the raw file
with SHA-256 and records the exact source commit, legacy version, Xcode, Swift,
architecture, scenario, and generation time. Captures must never be manually
authored or silently regenerated.

`Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/{advertise,deadvertise,discover-resolve}.jsonl`
and their manifests are real captures generated this way on a macOS 26 /
Xcode 26.6 / Apple Swift 6.3.3 (arm64) host against a local Mosquitto broker,
and decoded (not just parsed) by `LegacyCaptureFixtureTests.swift` in the
Swift test target. Generating them surfaced two real bugs in the previously
unexercised macOS runner, both fixed in
`Tests/WireCompatibility/Legacy/macOS-runner/Sources/LegacyCoatySwiftScenarioRunner/main.swift`:

- Pinned CoatySwift 2.4.0's CocoaMQTT client dispatches its socket delegate
  callbacks on the main dispatch queue. The runner's `Thread.sleep` and
  `DispatchSemaphore.wait` calls block that same thread without ever spinning
  its run loop, so the MQTT CONNECT/CONNACK handshake (and every subsequent
  PUBLISH) never actually ran — the process printed `"state":"done"` while
  publishing nothing. The runner now uses a `RunLoop`-pumping sleep/wait
  helper instead.
- The Discover/Resolve requester and responder identity UUIDs
  (`...000201` / `...000202`) only differed after the 18th hex digit, but
  CoatySwift derives each client's MQTT ClientID from exactly that
  18-character prefix. Both clients computed the same ClientID, so the
  broker repeatedly disconnected whichever one had connected first every time
  the other (re)connected, and the scenario never completed. The responder's
  identity now differs within that prefix.

If you regenerate these captures, verify with `mosquitto_sub -h 127.0.0.1
-p 1883 -t '#' -v` (or equivalent) that real Advertise/Deadvertise/Resolve
traffic is actually on the wire before trusting a `"state":"done"` line —
that exact false-positive is what the first bug above produced.

## Linux validation and replay

Manifest generation is performed by the Node wire CLI; semantic validation is
performed by the Swift Testing wire suites:

```sh
node Tests/WireCompatibility/tool/dist/index.js legacy-manifest \
  Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/advertise.jsonl \
  Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/advertise.manifest.json \
  --version 2.4.0 --source-commit COMMIT --scenario advertise
```

Run the wire suites with:

```sh
make test-wire
```
