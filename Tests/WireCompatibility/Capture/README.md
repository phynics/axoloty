# MQTT wire capture

`mqtt_capture.py` is a dependency-free, passive MQTT 3.1.1 subscriber. It
records each publication as one JSON object per line without decoding or
rewriting its payload. Raw payload bytes are base64 encoded, so captures are
lossless even when a producer sends malformed or non-UTF-8 data.

Run it beside a pinned reference agent:

```sh
python3 Tests/WireCompatibility/Capture/mqtt_capture.py \
  --producer coatyjs \
  --producer-version 2.0.0 \
  --scenario advertise \
  --topic 'coaty/#' \
  --count 1 \
  --output /tmp/coatyjs-advertise.jsonl
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

The probe supports QoS 0 and 1 subscriptions. Coaty compatibility scenarios
currently need no QoS 2 handshake; the probe fails explicitly if one is
received instead of producing a misleading partial capture.
