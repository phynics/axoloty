# G2 protocol traces

This directory owns the versioned, test-only trace contract for G2. A trace
records prior state, capabilities, finite limits, logical time, fixture input,
the local operation boundary, normalized actions, structured rejection, and
next state. The JSON schema is [`trace.schema.json`](trace.schema.json).

The corpus has accepted and malformed cases for each of the thirteen Coaty Core
wire families, plus bounded saturation, duplicate, stale-correlation,
unsupported, deadline, and payload-limit cases. `ContractTraceReplayAdapter`
is a deterministic contract adapter used only to prove the seam and equality
runner. G2's shared processor replaces it; no trace type here is a product API.

`IoState` is intentionally not a family: it is a local association signal and
is not published on MQTT.
