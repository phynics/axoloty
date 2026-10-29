# Zenoh dependency pinning

Pinned revisions, licenses, and qualification evidence for the Zenoh transport
([epic #796](https://github.com/phynics/axoloty/issues/796)). Zenoh's
repositories develop together and their git revisions do not necessarily match
each other's packaged releases, so every component is pinned to an exact
released version rather than a branch.

The binding carries only the `axoloty/1` CBOR profile
([ADR 0009](../adr/0009-zenoh-carries-only-axoloty-1.md)); MQTT keeps the
sealed `coaty/3` JSON profile. Zenoh peers built on 0.9.x do not interoperate
with 1.0 Zenoh peers.

## Version matrix

| Component | Version | Revision | Role |
|---|---|---|---|
| `eclipse-zenoh/zenoh` (`zenohd`) | `1.10.0` | release tag `1.10.0` | Router used by host and embedded integration tests |
| `eclipse-zenoh/zenoh-c` | `1.10.0` | release tag `1.10.0` | Host backend for the Axoloty C façade |
| `eclipse-zenoh/zenoh-pico` | `1.10.0` | `96006957fddef401c20c8c2d813c2a630b666974` | ESP-IDF backend for the Axoloty C façade |

All three were published on 2026-08-14 and are the aligned latest release of
each repository. They must be bumped together: Zenoh publishes `zenoh`,
`zenoh-c`, and `zenoh-pico` as one coordinated release train, and mixing
versions across that train is unsupported.

The `zenoh-pico` `1.10.0` tag is an annotated tag object, so the commit SHA
above — not the tag object's own SHA — is the revision to check out.

### Licenses

Every component is dual-licensed `Apache-2.0 OR EPL-2.0`. Both are permissive
and compatible with Axoloty's MIT license. GitHub's license classifier reports
`NOASSERTION` for all three because it does not resolve the dual-license
`LICENSE` file; the file itself states both licenses explicitly.

## Host artifacts

`zenoh-c` publishes prebuilt `*-standalone` archives per release. Axoloty
pins and supports two of them:

| Platform | Asset | Support |
|---|---|---|
| Linux x86_64 | `zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone.zip` | Supported (pinned container) |
| macOS arm64 | `zenoh-c-1.10.0-aarch64-apple-darwin-standalone.zip` | Supported (native toolchain) |
| Linux aarch64 | `zenoh-c-1.10.0-aarch64-unknown-linux-gnu-standalone.zip` | Unsupported |
| macOS x86_64 | `zenoh-c-1.10.0-x86_64-apple-darwin-standalone.zip` | Unsupported |

Each archive contains headers, both a static and a shared library, a CMake
package configuration, and a pkg-config file:

```text
include/zenoh.h  (+ zenoh_commons.h, zenoh_concrete.h, …)
lib/libzenohc.a
lib/libzenohc.so
lib/cmake/zenohc/zenohcConfig.cmake
lib/pkgconfig/zenohc.pc
```

Consuming these archives is why building `zenoh-c` from source — and therefore
requiring a Rust toolchain — is not necessary on the host. See
[ADR 0006](../adr/0006-zenoh-host-dependency-packaging.md) for the packaging
decision and [ADR 0010](../adr/0010-zenoh-supported-host-matrix.md) for the
supported host set.

`zenohc.pc` hardcodes `prefix=/usr/local`. When the archive is unpacked
anywhere else, the `prefix` line must be rewritten before `pkg-config` will
resolve it.

The Darwin `libzenohc.dylib` records the upstream CI build path
(`/Users/runner/work/zenoh-c/...`) as its install name, so a product linked
against the unmodified archive cannot load it. Provisioning rewrites the
install name to `@rpath/libzenohc.dylib` with `install_name_tool` and applies
an ad-hoc signature, because the rewrite invalidates the original one.
SwiftPM keeps only `-L` and `-l` from pkg-config output, and macOS strips
`DYLD_LIBRARY_PATH` from its protected launchers, so the Darwin tiers pass
`-Xlinker -rpath -Xlinker <zenoh-c>/lib` to `swift test`.

Verified SHA-256 of the archives used for qualification. The Darwin digests
match the digests GitHub publishes for the release assets:

```text
1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1  zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone.zip
43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881  zenoh-1.10.0-x86_64-unknown-linux-gnu-standalone.zip
0f5aed4e9e618b13d37518c8c19fb03210050843ca0cf7b6105f367a6c32a97c  zenoh-c-1.10.0-aarch64-apple-darwin-standalone.zip
00432b7efe7e84a230bad98b0995b5c2ab3757e8501c126f3b2d239fc0931610  zenoh-1.10.0-aarch64-apple-darwin-standalone.zip
```

The tiers provision only these two hosts: Linux x86_64 in the pinned
container, and macOS arm64 with the native toolchain. Any other host fails
before downloading.

## Live host integration

The opt-in `zenoh-live` tier downloads the pinned `zenohd` and `zenoh-c`
archives, verifies both checksums, rewrites `zenohc.pc` for the extracted
location, and removes neither the archives nor logs until the caller clears its
`.build/zenoh-live` scratch space. The tier owns a unique TCP port and router
process for each run, then runs the live `AxolotyZenoh` suite and terminates the
router on exit.

Run it through the pinned Linux container with host networking:

```sh
CONTAINER_NETWORK=host make test-tier TIER=zenoh-live BUILD_DIR=.build
```

On macOS arm64, run it with the native toolchain:

```sh
swift run --package-path Tools axoloty-tool test-tier zenoh-live
```

The scenarios cover two host `ZenohBinding` clients, an independent C client in
both directions, an external IO route, runtime soft recovery after killing and
restarting `zenohd`, and graceful transport shutdown. This tier is separate
from `make verify`; it is selected by the `Zenoh live integration` workflow on
`exploration/zenoh`.

## Offline host verification

The `zenoh-offline` tier proves the package without a router. It never starts
`zenohd`. It has two nodes:

- `zenoh-offline-package` provisions only the pinned `zenoh-c` archive through
  the same checksum-verified path as `zenoh-live`, under
  `.build/zenoh-offline`. It then runs every `AxolotyZenoh` package test except
  `ZenohLiveIntegrationTests`: the façade contract suite, `AxolotyZenohCoreTests`,
  the `ZenohBinding` and receive-pump suites, and the protocol trace parity
  replay. These are the tests that `Packages/AxolotyZenoh/Tests/run-sanitized-tests.sh`
  runs, without sanitizers.
- `zenoh-core-embedded` compiles `AxolotyZenohCore` and `AxolotyWire` as
  Embedded Swift for `riscv32-none-none-eabi` and partially links them. It
  needs no `zenoh-c` archive: the core reaches Zenoh only through the
  self-contained façade header. The only unresolved symbols it allows are the
  `axoloty_zenoh_*` façade entry points, which firmware supplies, and the
  runtime symbols that the Core Embedded Swift gate also allows.

```sh
make test-tier TIER=zenoh-offline
```

On macOS arm64, the native tier runs only `zenoh-offline-package`.
`zenoh-core-embedded` stays Linux-only, like the Core Embedded Swift gate:

```sh
swift run --package-path Tools axoloty-tool test-tier zenoh-offline
```

The `Zenoh offline` workflow runs this tier for pull requests and pushes to
`main` and `exploration/zenoh`. The tier is not in the `ci` tier, so
`make verify` is unchanged. The package node downloads the pinned archive, and
it builds the separate Zenoh package, which the root package never resolves.

## Qualification evidence

### Host (Linux x86_64, Swift 6.3, `axoloty-dev` container)

A scratch SwiftPM package consuming `zenoh-c` through a `.systemLibrary`
target with `pkgConfig: "zenohc"` compiles, links, and runs. A Swift
subscriber and a Swift publisher exchanged a message through a real
`zenohd 1.10.0`:

```text
PROBE_SUBSCRIBED coaty/3/probe/ADV/probe-source
PROBE_PUT rc=0
PROBE_RECEIVED coaty/3/probe/ADV/probe-source -> {"probe":true}
PROBE_ROUNDTRIP_OK
```

The Coaty route was carried unchanged as a Zenoh key expression, which is the
behavior AD-5 requires. **This capture predates ADR 0009.** Zenoh now carries
only the `axoloty/1` CBOR profile, so current keys read
`axoloty/1/<namespace>/<event>/<identifier>` and the binding labels every
published payload `application/cbor`. The probe above was not re-run; MQTT
still uses the sealed `coaty/3` JSON profile.

### Host (Linux x86_64, Swift 6.4, Core v0.10 candidate)

The current host-client evidence was run in the pinned `axoloty-dev` container
from the task worktree based on Core commit
`ac92751888c065a13f6c1a2ed7c31570913484f3`. The native inputs were the pinned
`zenohd 1.10.0` standalone archive (SHA-256
`43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881`) and
`zenoh-c 1.10.0` standalone archive (SHA-256
`1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1`). The
upstream `zenoh` 1.10.0 tag resolved to commit
`c479f0c1102d7321c2fa83f515bddede92014cce`; `zenoh-c` 1.10.0 resolved to
`7d586a9c19c0623144e06bd795e8c2b85dd722d4`. The router announced readiness
on a unique loopback TCP endpoint before tests started. The exact façade
source contract was 2.2.0, ABI generation 2. The Axoloty tool runner and
provisioner are from the `ac92751888c065a13f6c1a2ed7c31570913484f3` checkout;
their source hashes and the development-container input hash are in the task
evidence bundle.

`make test-tier TIER=zenoh-offline NODE=zenoh-offline-package` passed 41
package tests and 7 core tests. They exercise the real `zenoh-c` implementation
and assert ABI result mapping, session open/close and slot reuse, router-count
status and invalid arguments, owned subscriber handles, four-frame queue
saturation, over-limit key and payload reporting, advisory Encoding handling,
and borrowed-buffer copy behavior. The package tier provisions the pinned
archive and verifies its checksum; it does not start a router.

`CONTAINER_NETWORK=host make test-tier TIER=zenoh-live` passed on the same
host. The router-assisted client suite passed two Axoloty clients,
Axoloty-to-independent-C and C-to-Axoloty traffic, a full native receive queue
with reported drops, an over-limit native sample counted as oversized without
delivery, and graceful session shutdown. In the production runtime recovery
case, one CBOR Query with correlation
`22222222-2222-4222-8222-222222222222` arrived before the router was killed;
the sessions detected loss, the runtime entered reconnecting, and both
sessions and the runtime recovered after router restart. One CBOR Channel
publication arrived after recovery, and the Query count remained one, so the
accepted request was not replayed. The run also passed a separate routerless
peer scenario: three host bindings exchanged an external route over local
multicast, then the remaining peer continued receiving after another peer
stopped. This is host-only local-link evidence; it does not claim device peer
support.

A fresh SwiftPM consumer selecting the separate `AxolotyZenoh` package from
this exact worktree built and ran in the pinned container. `ldd` resolved
`libzenohc.so` from the checksum-verified `zenoh-c 1.10.0` archive. A second
fresh consumer selected only the root `Axoloty` product, built and ran with no
Zenoh environment configured, and had no `libzenohc` entry in `ldd`. These are
local-checkout exact-candidate proofs. The separate package remains a checkout
package with native provisioning; immutable public-revision consumption must
be repeated by the release owner after publishing the exact release head.

Run output and consumer link maps are retained with the task evidence bundle
under `/tmp/axoloty-batch2-382c4846/core-v010-zenoh-luna-evidence/`. These results
qualify Linux x86_64 only. No new macOS, iOS, firmware, device, or external
network claim is made. The Zenoh products remain experimental under ADR 0012;
these host test results do not promote them into the stable product set.

### Host (macOS 26.6 arm64, Xcode 27, Swift 6.4, native)

Both host tiers pass natively through `axoloty-tool test-tier` against the
pinned `aarch64-apple-darwin` archives. `zenoh-offline` passes the façade
conformance suite, the core, binding, and receive-pump suites, and the MQTT and
Zenoh protocol trace parity replay. `zenoh-live` passes every router scenario,
including soft recovery after `zenohd` is killed and restarted. See
[#972](https://github.com/phynics/axoloty/issues/972).

### Embedded (ESP32-C6, ESP-IDF v5.4, riscv32-esp-elf-gcc 14.2.0)

`zenoh-pico 1.10.0` compiles and links for `esp32c6` with the Axoloty v1
feature profile: 0 errors, 3 warnings, all of them pre-existing
unused-variable/unused-function warnings in `zenoh-pico`'s own sources that
follow from disabling query, queryable, and liveliness. No `-Wno-error` or
other warning suppression is required.

Static footprint contributed by `libzenoh_pico.a`:

| Section | Bytes |
|---|---|
| Flash `.text` | 68,568 |
| Flash `.rodata` | 739 |
| DIRAM `.data` | 24 |
| `.bss` | 0 |
| **Total** | **69,331** |

These are static-link figures only. Runtime heap, task stacks, and receive
buffers are not measured here; they are the subject of the hardware
qualification gate ([#818](https://github.com/phynics/axoloty/issues/818)).

## ESP-IDF integration constraints

`zenoh-pico` does not ship an ESP-IDF component. There is no
`idf_component_register` anywhere in its tree, and it is not published on the
Espressif component registry. Axoloty must therefore own a component wrapper
([#813](https://github.com/phynics/axoloty/issues/813)). Three specific
constraints came out of the qualification build:

- **Upstream does not test the configuration Axoloty uses.** `zenoh-pico`'s
  `espidf` CI builds through PlatformIO with `platform=espressif32@6.13.0`,
  targeting an Xtensa ESP32 board. It pins that platform deliberately, because
  `espressif32@7.0.0` pulls ESP-IDF 6.0 and exposes an unresolved
  source-selection problem. Axoloty builds natively through `idf.py` against
  ESP-IDF v5.4 targeting RISC-V `esp32c6` — neither the build system, the IDF
  version, nor the chip architecture matches upstream CI. The combination
  works, but Axoloty owns its regression coverage rather than inheriting it.

- **The component wrapper must generate two headers.** `include/zenoh-pico.h`
  and `include/zenoh-pico/config.h` are `configure_file` outputs, not
  checked-in sources. They must be generated *before* `idf_component_register`,
  which rejects an `INCLUDE_DIRS` entry that does not yet exist.

- **`esp_driver_uart` is required even with serial links disabled.**
  `zenoh-pico`'s `espidf` platform header includes `<driver/uart.h>`
  unconditionally, regardless of `Z_FEATURE_LINK_SERIAL`.

The qualified v1 feature profile is client mode over TCP with publication and
subscription only, per AD-6 and AD-7: query, queryable, liveliness, matching,
advanced publication/subscription, scouting, multicast, peer mode, and the
serial, Bluetooth, WebSocket, and TLS links are all disabled. `FRAG_MAX_SIZE`
and `BATCH_UNICAST_SIZE` are reduced from the 4096/2048 defaults to 1024 each,
and `Z_RUNTIME_MAX_TASKS` from 64 to 8. Those values are a starting point
chosen for a constrained target, not a measured optimum; the hardware gate
sets the final numbers.

## Unsupported hosts and device evidence

- **macOS x86_64 and Linux aarch64 are unsupported hosts.** Upstream publishes
  archives for both, but Axoloty pins no checksum for them and provisioning
  refuses them. Supporting either requires pinning its archive and running
  the `zenoh-offline` and `zenoh-live` tiers on it. The supported host set is
  recorded in
  [ADR 0010](../adr/0010-zenoh-supported-host-matrix.md).
- **On-device `zenoh-pico` execution is qualified in
  [`phynics/axoloty-embedded`](https://github.com/phynics/axoloty-embedded/issues/8),**
  which owns firmware builds, flashing, and device evidence. This repository
  records no device results.
