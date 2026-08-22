# AxolotyStaticRuntime instructions

## Jurisdiction

This guide applies to `Packages/AxolotyStaticRuntime/`. The root
[`AGENTS.md`](../../AGENTS.md) rules apply; this guide specializes them for
the synchronous Embedded profile.

## Specialized rules

`AxolotyStaticRuntime` owns only fixed composition: one
`ProtocolProcessor<capacity>`, one `ProtocolSubscriptionRegistry<capacity>`,
and one caller-drained `InlineProtocolActionSink<capacity>`. It must use the
same processor semantics as the host runtime and may not add a family switch,
transport policy, actor, task, Foundation, MQTT/NIO, logging, or controller.

All inputs are borrowed only for synchronous calls. Actions must be drained
before their source buffers leave scope. Handler entries are noncapturing thin
functions with numeric context handles. Runtime state is fixed inline and
saturation or stale-token rejection must leave state unchanged.

The accepted profile aliases are `tiny = 1`, `esp32C6Static = 16`, and
`hostDefault = 64`; these are storage capacities, not scheduling limits.
