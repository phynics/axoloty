---
status: accepted
---

# Keep the Zenoh adapter in its own SwiftPM package

[ADR 0006](./0006-zenoh-host-dependency-packaging.md) decides how SwiftPM
obtains `zenoh-c`: prebuilt standalone archives through a `.systemLibrary`
target, never a source build. It assumes the Zenoh code is "a separate
package/target that no existing product depends on" but does not decide which
of those two it is. This ADR records that boundary.

[Epic #796](https://github.com/phynics/axoloty/issues/796) requires that
`swift build` for existing Axoloty products stays unaffected on a machine
without Zenoh, and that consumers who never import the Zenoh adapter need
nothing installed. The root package's build graph is resolved and built by
every repository developer and by `make verify`, so the boundary has to be
mechanical rather than conventional.

## Decision

The Zenoh adapter lives in `Packages/AxolotyZenoh`, with its own
`Package.swift`, as a separate SwiftPM package. It depends on the root
`Axoloty` package by path.

The root `Package.swift`, `Package.resolved`, and module-policy target graph
gain no Zenoh target, product, target dependency, or system-library
declaration. `AxolotyZenohCore` (portable, Embedded-Swift-compatible) and
`AxolotyZenoh` (host runtime transport) are products of the subpackage.
`CZenohC`, the `.systemLibrary` that consumes the pinned archive from ADR 0006,
is a target of the subpackage.

The root repository still owns the Zenoh contracts (this ADR, ADR 0006, and
`docs/dependencies/zenoh.md`) and the host/shared work, per the ownership
boundary of [epic #845](https://github.com/phynics/axoloty/issues/845). Only
the SwiftPM package boundary moves.

## Rejected alternatives

**A trait-gated root target.** SwiftPM traits
([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md))
can conditionally enable a dependency, but a target or product is not removed
from the manifest, so the adapter target would still compile on every build —
empty behind `#if`. Traits also resolve after dependency resolution, so the
optional dependency can be fetched regardless. `AxolotyMQTT` needs no such
escape because it has no external native dependency; Zenoh's does not change
the rule that a carrier is a sibling adapter rather than a modification of the
root.

**An always-on root target.** Adding `AxolotyZenoh` as a normal root product
makes bare `swift build` and repository verification require a provisioned
`zenoh-c`, which is exactly the condition
[#798](https://github.com/phynics/axoloty/issues/798) exists to prevent.

**A separate target inside the root package.** This still puts the system
library and its `pkgConfig` lookup in the root manifest, so every root build
performs the lookup. The package boundary is what makes "unaffected without
Zenoh installed" true rather than assumed.

## Consequences

- `swift build`, `make verify`, and `make explain` at the root are unaffected;
  a machine without `zenoh-c` can develop and verify every existing product.
- A consumer selects Zenoh by adding the subpackage dependency, mirroring how
  it selects `AxolotyMQTT`. `AxolotyZenoh` is not a root product and is not
  discovered by depending on `Axoloty` alone.
- `docs/module-policy.yml` gains entries for the subpackage targets with paths
  under `Packages/AxolotyZenoh/`, and `axoloty-tool repository validate` must
  enumerate targets across both packages.
- Promoting the adapter to a root product once Zenoh is validated is a new
  decision, not a variation of this one.
