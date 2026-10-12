---
status: accepted
---

# Restrict the supported Zenoh host matrix to Linux x86_64 and macOS arm64

[ADR 0006](./0006-zenoh-host-dependency-packaging.md) consumes prebuilt
`zenoh-c` standalone archives through a `.systemLibrary` target. Its context
states that upstream publishes archives for Linux x86_64/aarch64 and macOS
x86_64/arm64, "which is Axoloty's entire host matrix". Qualifying and pinning
that dependency ([#797](https://github.com/phynics/axoloty/issues/797),
[#978](https://github.com/phynics/axoloty/issues/978)) showed that only two of
the four upstream hosts are actually supplied. This ADR narrows the host-matrix
claim recorded in
[#1003](https://github.com/phynics/axoloty/issues/1003). The packaging decision
in ADR 0006 stands unchanged.

## Context

`zenoh-c` publishes a standalone archive for each of four hosts, but Axoloty
pins a checksum and provisions only two of them. `docs/dependencies/zenoh.md`
records Linux aarch64 and macOS x86_64 as unsupported: no checksum is pinned
for them and provisioning refuses them.
[`docs/SUPPORT_MATRIX.md`](../SUPPORT_MATRIX.md) records the validated host as
the pinned Linux container and the best-effort Apple host as macOS arm64, which
is the only Apple host with recorded `zenoh-offline` and `zenoh-live` results.

An accepted ADR is not rewritten ([`AGENTS.md`](../../AGENTS.md)), so this ADR
supersedes only the host-matrix sentence in ADR 0006. Everything else that ADR
decides — prebuilt standalone archives, the `.systemLibrary` target, and the
façade constraints measured during qualification — remains in force.

## Decision

The supported Zenoh host matrix is:

| Host | Support | Evidence |
|---|---|---|
| Linux x86_64 | Supported | Pinned container; `zenoh-offline` and `zenoh-live` tiers |
| macOS arm64 | Supported (best effort) | Native toolchain; recorded `zenoh-offline` and `zenoh-live` results |

Linux aarch64 and macOS x86_64 are unsupported hosts. Upstream publishes a
`zenoh-c` archive for each, but Axoloty pins no checksum for them and
provisioning refuses them. Supporting either host requires pinning its archive
checksum and running the `zenoh-offline` and `zenoh-live` tiers on it; that is
a new decision rather than a variation of this one.

This ADR scopes only the Zenoh host artifacts. Support for the portable core on
other platforms is recorded separately in
[`docs/SUPPORT_MATRIX.md`](../SUPPORT_MATRIX.md).

## Consequences

- `docs/dependencies/zenoh.md` and `docs/SUPPORT_MATRIX.md` list exactly the
  two supported hosts and refer to this decision.
- Adding a host means pinning a new archive checksum and qualifying it through
  both Zenoh tiers; the packaging mechanism does not change.
- The sentence in ADR 0006 that the four upstream archives are Axoloty's
  entire host matrix is superseded.
