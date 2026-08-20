# G2 protocol traces

This directory owns the versioned, test-only trace contract for G2. A trace
records prior state, capabilities, finite limits, logical time, fixture input,
the local operation boundary, normalized actions, structured rejection, and
next state. The JSON schema is [`trace.schema.json`](trace.schema.json).

The corpus has fixture-backed accepted and genuinely malformed cases for each
of the thirteen Coaty Core wire families, plus bounded saturation, duplicate,
stale-correlation, unsupported, deadline, payload-limit, and typed external-route
cases. `HostTraceReplayAdapter` and `StaticTraceReplayAdapter` are independent
test-only implementations over the same contract; equality between them is the
G2 seam proof. G2's shared processor replaces them; no trace type here is a
product API.

The payload-limit case derives a 513-byte payload from the `CHN.valid` fixture;
its `fixtureID` records that deterministic derivation rather than naming a
nonexistent fixture file. External-route traces preserve Coaty's
`associatingRoute` field and the pinned binding fixture value
`external/wire-compat-v1/io-external-1`; the route classification is supplied
by the binding, with a separate rejection case for an inconsistent flag.

`IoState` is intentionally not a family: it is a local association signal and
is not published on MQTT.
