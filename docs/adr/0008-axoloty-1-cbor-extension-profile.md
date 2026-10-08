---
status: accepted
---

# Carry CBOR as the `axoloty/1` extension profile

[ADR 0002](./0002-seal-coaty-core-profile-3.md) seals `coaty/3` and directs
Axoloty-owned protocol growth into separately versioned extension profiles.
[Epic #977](https://github.com/phynics/axoloty/issues/977) evaluates a binary
wire encoding for Embedded Swift firmware and the Zenoh transport. This ADR
records where that encoding lives and how it is identified. Whether and when
it is implemented stays with the epic's measured go/no-go gate.

## Decision

`axoloty/1` is the first Axoloty extension profile. It carries the Coaty Core
Profile 3 event families and object semantics unchanged, encoded as CBOR
(RFC 8949) instead of JSON. Only the encoding differs.

- **Routes.** `axoloty/1` messages use routes of the form
  `axoloty/1/<namespace>/<event>/<sourceId>[/<correlationId>]`, with the same
  event codes, namespace rules, and route bounds as `coaty/3`. The route
  prefix is the authoritative encoding signal on every transport, because
  subscriptions partition on routes and MQTT 3.1.1 has no content type. A
  transport that supports encoding metadata (Zenoh `Encoding`) also labels
  the payload `application/cbor` as an advisory.
- **`coaty/3` is unchanged.** `coaty/3` routes carry JSON only. No CBOR,
  content negotiation, or new event code enters `coaty/3`, and its JSON output
  stays byte-identical. CoatyJS interoperability remains a `coaty/3` property.
- **Static selection.** Each transport binding selects its wire profile in
  its configuration: `coaty/3` (JSON), `axoloty/1` (CBOR), or, on host
  runtimes only, both for receive with one chosen for publish. There is no
  runtime negotiation or dynamic profile registration. Firmware may link only
  the profile it selects.
- **Defaults.** MQTT bindings default to `coaty/3`. Zenoh bindings and
  firmware without a CoatyJS peer are expected to default to `axoloty/1` once
  it is implemented.
- **Deterministic and bounded.** Writers emit RFC 8949 §4.2.1 core
  deterministic encoding with definite lengths. Readers reject
  indefinite-length items, duplicate map keys, tags outside an explicit
  allow-list, and nesting beyond a compile-time bound. The 256-byte route and
  2,048-byte payload caps and the zero-allocation hot path apply unchanged.
- **Protocol stays format-neutral.** Encoding is owned by `AxolotyWire` and
  selected by the binding. `AxolotyProtocol`, the static runtime, and
  transport adapters contain no encoding conditionals, so both profiles
  produce identical protocol traces.

Map-key representation (text keys or a versioned integer-key registry) and the
UUID representation are profile details. Epic #977 settles them from
measurements and records them in the `axoloty/1` protocol document before the
profile ships. Changing them after a release requires `axoloty/2`.

## Consequences

- JSON and CBOR are maintained in parallel for as long as `coaty/3`
  compatibility is a goal. Every wire DTO, fixture corpus, and parity gate
  gains a CBOR leg.
- An `axoloty/1`-only node cannot talk to CoatyJS directly. A mixed fleet needs
  a host runtime that receives both profiles.
- The public wire codec protocols cannot stay bound to the concrete JSON
  reader and writer. Either they gain a format seam or they leave the public
  API before Axoloty commits to API stability.
- The Zenoh transport should not ship a stable release that commits it to
  JSON as its long-term encoding.

## Rejected alternatives

**CBOR inside `coaty/3` routes**, signalled by content type or payload
sniffing. This breaks the sealed profile: CoatyJS subscribers would receive
payloads they cannot decode, and MQTT 3.1.1 cannot signal the difference.

**Encoding signalled only by transport metadata.** Subscriptions cannot filter
on Zenoh `Encoding` or MQTT 5 content type, so every subscriber would receive
and have to reject both encodings.

**MessagePack.** It is comparable in size but has no IETF standard,
deterministic-encoding rules, tag registry, or schema language (CDDL), and it
does not align with COSE for a later payload-security profile.

**A Zenoh-specific Coaty profile.** Epic #796 (AD-5) keeps Coaty routes
unchanged on Zenoh. The encoding choice is transport-independent, so it
belongs in a profile, not in one adapter.
