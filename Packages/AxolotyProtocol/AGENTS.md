# AxolotyProtocol instructions

## Jurisdiction

This guide applies to `Packages/AxolotyProtocol/`. The root [`AGENTS.md`](../../AGENTS.md)
rules apply; this guide specializes them for the portable protocol foundation.

## Specialized rules

`AxolotyProtocol` owns the sealed Coaty Core Profile 3 inventory, portable
routing keys and frame boundaries, protocol errors, bounded request state,
fixed-inline association/handler state, action sinks, and the shared
processor. It may depend on `AxolotyWire` for
Foundation-free wire views and fixed UUID/event primitives.

This package must remain free of Foundation, MQTT/NIO, ErrorKit, logging,
actors, controllers, lifecycle, and host object hierarchy dependencies. It
does not own a transport or runtime actor API. Host and Embedded Swift compile
the same production source files. Protocol state must use fixed storage and
explicit caller-supplied time; it must not allocate or start asynchronous
work. Actions use caller-owned bounded sinks and handlers use noncapturing
numeric-context entries.
