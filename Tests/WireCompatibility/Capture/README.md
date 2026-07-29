# MQTT wire capture

The `axoloty-wire capture` command is a passive MQTT 3.1.1 subscriber. It
records each publication as one JSON object per line without decoding or
rewriting its payload. Raw payload bytes are base64 encoded, so captures are
lossless even when a producer sends malformed or non-UTF-8 data.

Run it beside a pinned reference agent:

```sh
make wire-tool
node Tests/WireCompatibility/tool/dist/index.js capture 'coaty/#' \
  --producer coatyjs \
  --producer-version 2.0.0 \
  --scenario advertise \
  --count 1 \
  /tmp/coatyjs-advertise.jsonl
```

Each record preserves the exact topic, raw payload, requested delivery QoS,
retain and duplicate flags, capture order, producer/version, scenario, and
normalization profile. `capturedAt` describes the observation and is never a
wire compatibility assertion.

Reference captures belong below `Fixtures/<implementation>-<version>/` only
after the reference version and scenario have been reproduced. Do not hand
author or silently regenerate them. Review capture diffs together with
`normalization-rules.json`; normalization must not hide topic, QoS, retain,
field-presence, numeric-value, or array-order changes.

Offline verification is separate from capture:

```sh
make axoloty-tool AXOLOTY_TOOL_ARGS='wire verify'
```

This feeds checked-in topics and payload bytes directly to Swift tests and does
not start MQTT. Live capture remains an explicit evidence-production operation;
its manifest records producer/reference version, scenario, normalization
profile, and content hashes. Release workflows should retain raw capture and
manifest artifacts rather than relying on prose or screenshots.

Generate a release evidence bundle with `make release-snapshots` on Linux or
`swift run --package-path Tools axoloty-tool release snapshots` on macOS. The
generated `.testing/release-snapshots/manifest.json` records SHA-256 content
hashes, producer/scenario metadata, normalization profiles, and repository,
toolchain, and image provenance. Generation immediately performs an offline
hash and metadata verification pass.

The probe supports QoS 0 and 1 subscriptions. Coaty compatibility scenarios
currently need no QoS 2 handshake; the probe fails explicitly if one is
received instead of producing a misleading partial capture.
