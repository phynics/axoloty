# Axoloty versioning and deprecation policy

This policy defines how Axoloty versions releases and how the frozen 1.0
products change after the freeze. [`VERSION`](../VERSION) is the single source
of truth for the current release. [`CHANGELOG.md`](../CHANGELOG.md) and
[`docs/releases/`](./releases/) record each release.

## Version numbers

Axoloty follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
Release tags are `vMAJOR.MINOR.PATCH`.

Before 1.0:

- a minor release (`0.Y.0`) may include breaking public API changes; the public
  API may change at any minor release;
- a patch release (`0.Y.Z`) contains backward-compatible fixes and
  documentation only.

From 1.0:

- a major release may break or remove public API;
- a minor release adds backward-compatible public API and may deprecate API;
- a patch release contains only backward-compatible fixes.

The frozen products listed below are versioned together under the repository
`VERSION`. Their public API is the set of declarations reachable through each
published product.

## Frozen 1.0 products

The [1.0 scope](./ROADMAP.md) freezes exactly these products:

| Product | Owns |
|---|---|
| `Axoloty` | Host runtime lifecycle, scheduling, transport ownership, bounded ingress, and diagnostics. |
| `AxolotyWire` | Profile-neutral wire syntax, route envelopes, codecs, validation, and wire values. |
| `AxolotyProtocol` | Sealed profile inventory, routing keys, frame boundaries, bounded state, and the shared processor. |
| `AxolotyObjectModel` | Bounded semantic objects, schemas, presence, number and JSON views, and predicates. |
| `AxolotyStaticRuntime` | Fixed synchronous composition around one shared processor. |
| `AxolotyMQTT` | The MQTT transport adapter binding. |

Everything else is experimental for 1.0: `AxolotyZenoh`, `AxolotyZenohCore`,
`AxolotyCoatyModels`, `AxolotyIoRouting`, `AxolotySensorThings*`, the `Tools/`
harness, and the applications and debug products in the sibling
[`phynics/axoloty-debug`](https://github.com/phynics/axoloty-debug) package.
The deprecation policy below applies only to the frozen products.

## Deprecation policy

Deprecation is announced before removal so consumers have time to migrate.

1. **Signal in source.** Deprecated Swift API is annotated with
   `@available(*, deprecated, message:)` naming the replacement. The
   deprecation warning is the source-level contract.
2. **Record the change.** The deprecation is recorded in `CHANGELOG.md` under
   the release that introduces it and in that release's notes. Removed public
   symbols get a migration note under [`docs/migration/`](./migration/).
3. **Keep the window.** A deprecated symbol in a frozen product stays
   available for at least one minor release after it is deprecated. From 1.0
   it is removed no earlier than the next major release; before 1.0 it stays
   available through at least the next minor release.
4. **Remove only in a major.** From 1.0, removing a deprecated public symbol is
   a breaking change and requires a major release.

A change that keeps a symbol but changes its behavior is a breaking change and
follows the version rules above, not the deprecation window.

The deprecation window does not apply to:

- experimental products, which may change or be removed in any release;
- unreleased pre-1.0 API, which may change at any minor release;
- a security fix that cannot wait, which may remove or disable API in a patch
  release with the reason recorded in the release notes.

## Wire profiles

Wire contracts version separately from product versions.

- `coaty/3` is sealed ([ADR 0002](./adr/0002-seal-coaty-core-profile-3.md)).
  New behavior uses a separately versioned profile; `coaty/3` does not gain
  fields or operations.
- `axoloty/1` is the CBOR extension profile in 1.0 scope
  ([ADR 0009](./adr/0009-zenoh-carries-only-axoloty-1.md)). A breaking change
  to a profile is a new profile identifier, not a change to the frozen one.

## Support and security

Security support and the vulnerability reporting process are defined in
[`SECURITY.md`](../SECURITY.md). Per-capability and per-platform support levels
are recorded in [`docs/SUPPORT_MATRIX.md`](./SUPPORT_MATRIX.md).
