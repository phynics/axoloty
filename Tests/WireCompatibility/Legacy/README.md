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

## Linux validation and replay

Validation is dependency-free and does not claim to run legacy Swift:

```sh
python3 Tests/WireCompatibility/Legacy/validate_legacy_capture.py \
  Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/advertise.jsonl \
  --manifest Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/advertise.manifest.json
```

Replay first performs the same strict validation, then publishes the exact
topic and decoded payload bytes with the recorded QoS and retain flag:

```sh
python3 Tests/WireCompatibility/Legacy/replay_legacy_capture.py CAPTURE \
  --manifest MANIFEST --host 127.0.0.1 --port 1883
```

Replay is a consumer-compatibility input, not evidence that Axoloty reproduces
legacy timing, connection lifecycle, MQTT session settings, or duplicate
delivery behavior. Those require live cross-implementation scenarios.

Run the portable contract tests with:

```sh
python3 -m unittest discover -s Tests/WireCompatibility/Legacy -p 'test_*.py'
```
