---
status: accepted
---

# Consume prebuilt zenoh-c releases through a system-library target

The Zenoh transport ([epic #796](https://github.com/phynics/axoloty/issues/796))
needs `zenoh-c` on the host. `zenoh-c` is a Rust crate exposing a C ABI; built
from source it requires CMake and a Rust toolchain, and installs headers, a
static and a shared library, a CMake package configuration, and a pkg-config
file.

Axoloty cannot impose that on its consumers. The constraints are:

- consumers of `Axoloty` must not build Rust;
- consumers that do not import `AxolotyZenoh` must not need Zenoh installed at
  all;
- `swift build` for existing Axoloty products must remain unaffected;
- Linux and macOS must use the same conceptual solution.

The development image deliberately has no Rust toolchain today. `espflash` is
installed as a prebuilt binary specifically to avoid adding one.

## Decision

Consume the prebuilt `*-standalone` archives that `zenoh-c` publishes with
each release, and expose them to SwiftPM through a `.systemLibrary` target
with `pkgConfig: "zenohc"` and a module map. Do not build `zenoh-c` from
source, and do not add a SwiftPM build plugin that drives Cargo.

Upstream publishes standalone archives for Linux x86_64/aarch64 and macOS
x86_64/arm64, which is Axoloty's entire host matrix. Each contains headers,
`libzenohc.a`, `libzenohc.so`, a CMake package configuration, and
`lib/pkgconfig/zenohc.pc`. The exact revisions and checksums are recorded in
[`docs/dependencies/zenoh.md`](../dependencies/zenoh.md).

`zenohc.pc` hardcodes `prefix=/usr/local`. Provisioning must rewrite that line
when the archive is unpacked elsewhere, then put the resulting directory on
`PKG_CONFIG_PATH`.

Because `AxolotyZenoh` is a separate package/target that no existing product
depends on, a consumer that never imports it resolves no Zenoh dependency and
needs nothing installed.

### Rejected alternatives

**Build `zenoh-c` from source via a SwiftPM plugin.** This forces a Rust
toolchain onto every consumer that builds the package graph and makes build
times and reproducibility hostage to Cargo. The epic explicitly directs
against introducing a build plugin to compile Cargo unless simpler approaches
fail. They did not fail.

**Require an externally installed `zenoh-c`.** Workable but leaves version
drift unmanaged: nothing ties the installed library to the pinned revision,
and Zenoh's release train makes mixed versions unsupported. Provisioning a
pinned archive gives the same result with the version under our control. This
remains a valid escape hatch for a consumer that already manages Zenoh through
its own package manager, since a `.systemLibrary` target consumes whatever
`pkg-config` resolves.

**`.unsafeFlags` for include and link paths.** SwiftPM rejects `unsafeFlags`
in a package consumed as a dependency, so this would make `AxolotyZenoh`
unusable by exactly the consumers it is meant for.

**A binary target.** `.binaryTarget` accepts XCFrameworks, which are Apple-only,
and artifact bundles, which cover executables rather than linkable C
libraries. It cannot express one dependency for both Linux and macOS.

## Consequences

Provisioning becomes a documented, checksum-verified fetch-and-unpack step
rather than a compile. Bumping Zenoh means changing pinned versions and
checksums in `docs/dependencies/zenoh.md` and re-running provisioning; the
three Zenoh components must move together.

The host is bound to the platforms upstream publishes archives for. A platform
outside that set would need a source build, and that would be a new decision
rather than a variation of this one.

Swift sees `zenoh-c`'s headers directly through the module map, but only the
Axoloty C façade is permitted to use them. That boundary is AD-2's, not this
ADR's, and this decision does not weaken it: what is imported here is the
material the façade is built from, not the surface Axoloty code targets.

Two properties of that surface were measured while qualifying this decision
and constrain the façade rather than the packaging:

- `z_move`, `z_loan`, and `z_drop` are C11 `_Generic` macros. Swift does not
  import function-like macros, so they are unavailable; only the per-type
  `static inline` shims (`z_config_move`, `z_session_loan`, …) come through.
- A `z_view_*` value constructed over a transient Swift `String` is a dangling
  borrow as soon as the statement ends. Under allocation churn it was
  corrupted in 200 of 200 iterations, returning unrelated heap contents. It
  can appear to work in trivial cases, which makes it exactly the class of
  defect a façade taking caller-owned bytes must prevent.
