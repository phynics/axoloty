# Diagnostics

Axoloty keeps transport and protocol diagnostics bounded and separate from
application logging. A runtime exposes a coalesced ``RuntimeDiagnostics``
snapshot and a bounded diagnostics stream through
``AxolotyRuntime/diagnosticsSnapshot()`` and ``AxolotyRuntime/diagnostics()``.

The counters cover ingress saturation, stream drops, handler saturation,
reconnects, expired requests, malformed frames, and transport failures. A
diagnostic value is owned and sendable, so it may be recorded or forwarded to
an application's logger without retaining transport buffers.

Applications choose their own `swift-log` bootstrap and filtering policy.
Axoloty does not expose raw MQTT topics or transport-owned buffers through the
diagnostic API. Correlate a request/response exchange with the
`RuntimeEventContext.correlationID` value and use the context's route
classification when distinguishing the exact external compatibility route.

The static runtime provides the same bounded state and action outcomes through
its synchronous diagnostic snapshot. It does not create tasks or loggers on
the embedded hot path.
