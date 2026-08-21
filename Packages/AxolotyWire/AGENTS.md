# AxolotyWire instructions

## Jurisdiction

This guide applies to `Packages/AxolotyWire/`. The root [`AGENTS.md`](../../AGENTS.md) rules apply; this guide specializes them for the portable wire package.

## Specialized rules

`AxolotyWire` is the portable, profile-neutral wire boundary. It may own route/topic envelopes, codecs, wire validation, common object-envelope decoding, borrowed/owned wire values, caller-owned parser workspaces, and wire errors. Parser workspaces expose one storage-independent reader algorithm; embedded callers provide inline bytes and host callers provide reusable contiguous bytes.

Subscriber/router, endpoint, association, correlation, handler, and processor
state do not belong in this package; they are owned by `AxolotyProtocol`. The
package must remain free of MQTT/NIO, controllers,
lifecycle, actors, logging, Foundation, and ErrorKit. Borrowed values remain
synchronous and scoped; materialize owned values before any asynchronous or
isolation boundary.

Host and Embedded Swift builds must compile the same production sources. Conditional compilation may adapt unavailable mechanics but must not change protocol semantics.
