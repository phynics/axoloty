# MQTT wire capture

The `axoloty-wire capture` command is a passive MQTT 3.1.1 subscriber. It
records each publication as one JSON object per line without decoding or
rewriting its payload. Raw payload bytes are base64 encoded, so captures are
lossless even when a producer sends malformed or non-UTF-8 data.

Run it beside a pinned reference agent:

```sh
make wire-tool
node Tests/Support/WireCompatibility/tool/dist/index.js capture 'coaty/#' \
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

The offline fixture bundle is deliberately distinct from fresh wire evidence.
Generate it with `make release-fixture-bundle` on Linux or
`swift run --package-path Tools axoloty-tool release fixture-bundle` on macOS.
The generated `.testing/fixture-bundle/manifest.json` records SHA-256 content
hashes, producer/scenario metadata, normalization profiles, repository,
toolchain, and image provenance, and declares `evidence.type: fixture-bundle`
with `live: false`. It proves bundle integrity and byte-exact offline
reproduction of committed fixtures only; it is not a live capture of current
release wire behavior. Generation immediately performs an offline hash and
metadata verification pass. Fresh evidence of current wire behavior comes only
from the live reference-agent capture path (`wire-live`).

The probe supports QoS 0 and 1 subscriptions. Coaty compatibility scenarios
currently need no QoS 2 handshake; the probe fails explicitly if one is
received instead of producing a misleading partial capture.
