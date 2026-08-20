# AxolotyWire instructions

These rules specialize the repository-wide rules in the root `AGENTS.md` for this subtree.

`AxolotyWire` is the portable, profile-neutral wire boundary. It may own route/topic envelopes, codecs, wire validation, common object-envelope decoding, borrowed/owned wire values, caller-owned parser workspaces, and wire errors.

It must not own subscribers, async streams, correlation or association stores, endpoint registries, MQTT/NIO, controllers, lifecycle, actors, logging, Foundation, or ErrorKit. Borrowed values remain synchronous and scoped; materialize owned values before any asynchronous or isolation boundary.

Host and Embedded Swift builds must compile the same production sources. Conditional compilation may adapt unavailable mechanics but must not change protocol semantics.
