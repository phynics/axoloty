---
status: accepted
---

# Establish the portable object-model boundary

G3 introduces a value-oriented object model shared by the host and static
runtime profiles. The model is a semantic layer above `AxolotyWire`: wire
syntax, borrowed bytes, tokenization, and envelope-level decoding remain in
`AxolotyWire`; object schemas, bounded dynamic storage, semantic envelopes,
presence, predicates, and schema registration belong in
`AxolotyObjectModel`. `AxolotyProtocol` may adapt the model to Coaty protocol
filters and frames, but the model does not depend on a transport, runtime, or
protocol processor.

## Decision

Use one value-oriented object implementation specialized by explicit inline
capacity parameters. G3 will measure host and ESP32-C6 object byte/field
capacity points before selecting aliases; the 1/16/64 points accepted by G1
are runtime-state evidence, not object-model evidence. Dynamic storage owns an
inline byte arena and a fixed descriptor table. Unknown fields and original
number lexemes remain available for lossless round trips. Nested values remain
borrowed raw slices until accessed.
Mutation is a bounded, preflighted transition that commits atomically or
leaves the object byte-for-byte unchanged.

Typed schemas conform to a small `ObjectSchema` interface. A SwiftSyntax
macro may synthesize that conformance, descriptors, and field codecs, but its
expansion must be behaviorally equivalent to a manual conformance. The macro
package is build-time only and is not part of the portable runtime graph.

Schema registration is an explicit, runtime-local, fixed-inline registry. It
is idempotent for the same schema, rejects conflicts and saturation without
partial mutation, and becomes immutable through an explicit sealing
transition. There is no process-global registry, static registration side
effect, reflection lookup, or captured closure in the portable path.

Predicates use a bounded AST and literal arena. The object model owns the
generic AST and local evaluator; `AxolotyProtocol` owns only the Coaty filter
wire adaptation. Numeric operands preserve their source lexemes, and matching
does not require Foundation regular expressions.

## Dependency and implementation boundary

```text
AxolotyWire
    ↑
AxolotyObjectModel ← AxolotyObjectMacros (build time only)
    ↑
AxolotyProtocol
```

`AxolotyObjectModel` and its production consumers must remain free of
Foundation, MQTT/NIO, logging, ErrorKit, actors, controllers, lifecycle
frameworks, growable `Array`/`Dictionary` storage, and asynchronous runtime
state. Host-only object hierarchy and runtime composition remain in the root
`Axoloty` product until G4. The object-model boundary checker and its negative
self-tests enforce these exclusions and the required source inclusion once
the G3 packages land.

## Consequences

- Host and static profiles share semantic object and predicate behavior.
- Capacity is visible in type selection and is measured at explicit G3 byte
  and field points instead of hidden behind allocation.
- Unknown fields and numeric formatting are preserved by construction.
- Macro ergonomics do not become a runtime dependency or an Embedded Swift
  requirement.
- G4 can replace the inherited object hierarchy without re-deciding model,
  registry, or predicate semantics.

This ADR records the accepted seam; it does not claim that G3 production
packages or the runtime replacement are complete. G3 status is tracked by
issue [#631](https://github.com/phynics/axoloty/issues/631).
