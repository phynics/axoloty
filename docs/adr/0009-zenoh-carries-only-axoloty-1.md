---
status: accepted
---

# Zenoh carries only the `axoloty/1` CBOR profile

[ADR 0008](./0008-axoloty-1-cbor-extension-profile.md) defines `axoloty/1`:
the Coaty Core Profile 3 event families encoded as CBOR. It lets every
binding choose `coaty/3`, `axoloty/1`, or both, and expects Zenoh to default
to `axoloty/1` once the profile exists. This ADR replaces those selection
rules for Zenoh. Everything else in ADR 0008 stands: the profile definition,
the route prefix, deterministic and bounded encoding, and a format-neutral
`AxolotyProtocol`.

## Context

`coaty/3` is a compatibility profile whose only purpose is interoperability
with CoatyJS and legacy CoatySwift, and both speak it over MQTT only. A Coaty
agent on Zenoh is already outside the Coaty specification, so carrying JSON
on Zenoh buys no compatibility. It does cost a second encoding on the
transport, a dual-profile receive mode, and a JSON parser in Zenoh firmware.
The Zenoh transport shipped as experimental in 0.9.0, with its encoding
explicitly subject to change, so no stable consumer depends on JSON over Zenoh.

## Decision

- **Zenoh carries `axoloty/1` only.** Zenoh bindings, host and embedded,
  publish and subscribe on `axoloty/1/<namespace>/<event>/<sourceId>[/<correlationId>]`
  key expressions with CBOR payloads, labelled `application/cbor` in Zenoh
  `Encoding` metadata. They offer no `coaty/3` mode and no dual-profile mode.
  This revises epic #796's AD-5, which kept `coaty/3` routes unchanged on
  Zenoh.
- **MQTT carries `coaty/3` in v1.** MQTT bindings keep the sealed JSON profile
  for CoatyJS interoperability. ADR 0008 still permits `axoloty/1` over MQTT
  and a host binding that receives both profiles, but neither is part of the
  v1 scope.
- **One profile per binding.** A binding's wire profile follows from its
  transport and is not a configuration option in v1, so firmware links
  exactly one encoder and decoder. A Zenoh-only image links no JSON parser.
- **`axoloty/1` is part of the 1.0 scope.** Epic #977's G1 gate no longer
  decides whether CBOR ships. It settles the profile details that ADR 0008
  left open (map-key and UUID representation) from production-firmware
  measurements.

## Consequences

- A Zenoh peer built on 0.9.x, which uses `coaty/3` JSON, does not interoperate
  with the next release's Zenoh peers. That is acceptable for an experimental
  transport and is called out in its release notes.
- MQTT/Zenoh trace parity remains a protocol-level property: the same
  operations produce the same protocol trace, while the routes and payload
  bytes differ by profile.
- An MQTT/CoatyJS fleet and a Zenoh fleet are separate wire domains. Joining
  them requires a host application that runs both bindings. A general bridge
  remains out of scope.
- Zenoh embedded qualification happens once, on CBOR. A `coaty/3`-over-Zenoh
  device certificate would be superseded immediately and is not produced.
