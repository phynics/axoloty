---
status: accepted
---

# Size the protocol object aliases at the 2,048-byte wire payload bound

[ADR 0005](./0005-portable-object-model-boundary.md) states that the
protocol-sized `DynamicObject` and `Object<Schema>` aliases "use the 512-byte
payload and 24-field wire-authority bounds". Commit `0be11390` (released in
0.6.1) raised the wire payload limit to 2 KiB and resized both aliases with it.
The ADR text was not updated. This ADR records the implemented bound. An
accepted ADR is not rewritten ([`AGENTS.md`](../../AGENTS.md)), so this ADR
supersedes only that one sentence in ADR 0005.

## Context

The aliases are defined in
[`TypedObject.swift`](../../Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/TypedObject.swift):

- `DynamicObject = BoundedDynamicObject<2048, 24>`
- `Object<Schema> = BoundedObject<Schema, 2048, 24>`

The static runtime aliases use the same payload dimension
(`StaticRuntime<capacity, 2048>` in
[`StaticRuntime.swift`](../../Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/StaticRuntime.swift)),
and [`ARCHITECTURE.md`](../../ARCHITECTURE.md) already describes the
2,048-byte/24-field aliases as wire-authority bounds.

## Decision

The protocol-sized object aliases track the wire payload authority bound,
currently 2,048 bytes, and the 24-field bound. They are wire-authority bounds,
not resource presets. Callers that need a smaller footprint select an explicit
`BoundedDynamicObject` or `BoundedObject` specialization, as ADR 0005 already
allows.

Everything else in ADR 0005 remains in force: the object model sits above
`AxolotyWire`, capacity is explicit in type selection, mutation is atomic,
registration is explicit and runtime-local, and the macro package is build-time
only.

## Consequences

- A change to the wire payload authority bound changes these aliases in the
  same commit and needs no further ADR, provided the aliases stay equal to it.
- Selecting a different default for the aliases, or decoupling them from the
  wire bound, requires a superseding ADR.
- Embedded deployments that cannot afford 2,048-byte objects keep using
  explicit specializations; this ADR does not change any device budget.
