# Host runtime instructions

## Jurisdiction

This guide applies to `Source/Runtime/`. The root [`AGENTS.md`](../../AGENTS.md)
rules apply; this guide specializes them for the G4 host execution profile.

## Specialized rules

`AxolotyRuntime` owns host lifecycle, scheduling, transport ownership, bounded
ingress/dispatch, supervised handlers, and diagnostics. Every protocol
transition must enter `AxolotyProtocol`; this directory must not reimplement
the Coaty family switch or expose raw MQTT topics, wildcard subscriptions, or
transport-owned buffers.

`RuntimeDefinition` is mutable only before sealing. `AxolotyRuntime` is
single-use, actor-isolated, and bounded. Transport callbacks copy data before
admission; a full ingress queue fails the runtime rather than dropping a
protocol frame. Handler inputs and event-stream values are owned and sendable,
and foreign errors are wrapped at this boundary.

The host may use reusable contiguous storage and Foundation-backed transport
adapters. It must not add a second protocol processor, compatibility facade,
controller lifecycle, process-global registry, or unbounded task-per-message
delivery path.
