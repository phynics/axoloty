# AxolotyStaticRuntime instructions

## Jurisdiction

This guide applies to `Packages/AxolotyStaticRuntime/`. The root
[`AGENTS.md`](../../AGENTS.md) rules apply; this guide specializes them for
the synchronous Embedded profile.

## Specialized rules

`AxolotyStaticRuntime` owns only fixed composition: one
`ProtocolProcessor<capacity>`, one `ProtocolSubscriptionRegistry<capacity>`,
one caller-drained `InlineOwnedProtocolActionSink<capacity>`, and one
slot-indexed static IO endpoint registry. The endpoint registry stores
composition (typed handles, normalized endpoint snapshots, generated handler
entries, publication timing, and one pending latest value); association and
route truth remain in the processor. It must use the same processor semantics
as the host runtime and may not add a family switch, transport policy, actor,
task, Foundation, MQTT/NIO, logging, or controller.

All inputs are borrowed only for synchronous calls. The owning sink deep-copies
protocol actions before the processing call returns and rematerializes borrows
only inside synchronous drain visitors. Handler entries are statically
noncapturing function pointers with numeric context handles. Runtime state is
fixed inline and saturation or stale-token rejection must leave state unchanged.

The accepted profile aliases are `tiny = 1`, `esp32C6Static = 16`, and
`hostDefault = 64`; these are storage capacities, not scheduling limits.
