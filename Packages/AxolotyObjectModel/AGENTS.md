# AxolotyObjectModel instructions

## Jurisdiction

This guide applies to `Packages/AxolotyObjectModel/`. The root [`AGENTS.md`](../../AGENTS.md)
rules apply; this guide specializes them for the portable G3 object model.

## Specialized rules

`AxolotyObjectModel` owns semantic object envelopes, bounded dynamic and typed
objects, schemas, presence, JSON value/number views, predicates, and explicit
runtime-local schema registration. `AxolotyWire` remains the owner of wire
syntax, tokenization, borrowed bytes, and low-level envelope decoding.

The package must compile the same production source files for host and
Embedded Swift. It must remain free of Foundation, MQTT/NIO, logging,
ErrorKit, actors, controllers, lifecycle frameworks, transports, and runtime
tasks. Do not introduce `Array` or `Dictionary` storage, reflection, global
mutable registries, static registration side effects, or captured closures.
Use literal-inline storage and explicit capacity parameters. Saturation,
malformed input, and mutation failures must be atomic.

Borrowed views are synchronous and scoped. Materialize owned values before an
asynchronous or isolation boundary; this package itself must not create such a
boundary. Unknown fields and original JSON number lexemes must survive typed
decode/edit/encode cycles.

The schema registry is runtime-local, fixed-inline, explicitly populated, and
sealed by the caller. Repeated identical registration is idempotent; conflicts
and saturation fail without partial state changes.
