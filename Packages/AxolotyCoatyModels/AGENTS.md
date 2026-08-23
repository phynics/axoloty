# AxolotyCoatyModels instructions

## Jurisdiction

This guide applies to `Packages/AxolotyCoatyModels/`. The root
[`AGENTS.md`](../../AGENTS.md) rules apply; this guide specializes them for the
first-party portable Coaty model package.

## Specialized rules

`AxolotyCoatyModels` owns first-party convenience schemas built on
`AxolotyObjectModel`. It is a separate product and must not pull the inherited
class hierarchy into the portable path. Add a schema only when its complete
portable value representation is implemented; do not publish hollow marker
types for list- or graph-bearing models whose bounded representation is still
undecided.

The package compiles the same production sources for host and Embedded Swift.
It must remain free of Foundation, MQTT/NIO, ErrorKit, logging, actors,
controllers, lifecycle frameworks, transports, reflection, global mutable
registration, growable `Array`/`Dictionary` storage, and stored or escaping
captured closures. Use fixed-inline values, preserve the pinned Coaty wire
names and defaults, validate semantic requirements such as non-empty IO value
types, and fail atomically on bounded overflow.
