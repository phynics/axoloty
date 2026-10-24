# External consumer validation

## Supported acquisition boundaries

Applications consume the stable products from the public root package URL. A
consumer selects the products it needs with SwiftPM target dependencies; it
does not use a local path override or a sibling checkout. The root package is
the acquisition unit for all six stable products:

| Product | Consumer exercised |
|---|---|
| `AxolotyWire` | Focused Wire-only executable |
| `AxolotyProtocol` | Portable product consumer and transport SPI consumer |
| `AxolotyObjectModel` | Portable product consumer |
| `AxolotyStaticRuntime` | Portable product consumer |
| `Axoloty` | Core-only, MQTT composition, and transport SPI consumers |
| `AxolotyMQTT` | Host MQTT composition consumer |

`make test-axoloty-semver-consumer` resolves the root URL into a fresh temporary
consumer. Set `AXOLOTY_CONSUMER_REVISION` to a full immutable 40-character git
revision and explicitly set `AXOLOTY_CONSUMER_LOCAL=0` for revision-based
validation, or set `AXOLOTY_CONSUMER_VERSION` for a published semantic
version. By default, the check builds and runs every consumer in debug and
release configurations. `AXOLOTY_CONSUMER_SCOPE=core-wire` limits it to fresh
Core-only and Wire-only consumers for packaging-boundary checks. The focused
scope still uses the canonical public root URL when local mode is disabled.
`AXOLOTY_CONSUMER_EVIDENCE_DIR` retains the
manifest, resolution, build and run logs, toolchain, platform, and provenance
outside the temporary consumer directory. Without that override, evidence is
retained under `.build/external-consumer-evidence/`.

The Make target defaults `AXOLOTY_CONSUMER_LOCAL=1` for pre-release use.
`AXOLOTY_CONSUMER_LOCAL=1` is a synthetic fixture. It creates a
temporary `file://` remote, synthetic tag, and URL rewrite for the pinned
`swift-json` revision. Its result is fixture evidence only; it does not prove
public remote acquisition. Do not combine local mode with revision mode.

The Wire-only target uses the root URL and builds and links without compiling
host runtime targets. SwiftPM resolves the root package graph before selecting
that target, so resolution may fetch host dependencies. That package-level
resolution is not host product linkage. The checker records both the resolved
graph and the target build log, and rejects host-target compilation in the
Wire-only build.

`AxolotyZenoh` remains experimental in its separate nested package. A root URL
consumer cannot select a SwiftPM package manifest from a repository
subdirectory; host consumers use the documented checkout workflow and pinned
native provisioning in [ADR 0014](adr/0014-optional-zenoh-root-packaging-disposition.md).

The host MQTT consumer constructs the public `RuntimeBuilder`, immutable
definition, and `MQTTBinding`. It does not connect to a broker. The transport
SPI consumer supplies its own in-memory implementation of the public runtime
transport protocol, starts and stops a runtime, and verifies that startup
effects reached the adapter. It also reads the public diagnostics snapshot,
checks the running and stopped lifecycle plus declared capabilities and finite
stream capacity, then submits an empty public `discover` request. The consumer
asserts the typed malformed-payload rejection, the changed diagnostic counters,
and the matching owned request observation from the diagnostics stream. Stream
consumption has an explicit cancellation-backed deadline. The consumer uses no
repository test support.

Firmware uses a separate boundary. A firmware consumer checks out Axoloty and
sets `AXOLOTY_SOURCE_DIR` to that checkout. It prepares its own consumer space
with `axoloty-tool embedded consumer prepare` and
[`docs/embedded-consumer-contract.json`](embedded-consumer-contract.json).
That contract does not copy portable source or expose the repository's root
build directory or tests. The Core Embedded Swift gate remains the authority
for the portable source boundary; it is hardware-free and does not validate a
firmware product or board.

## Platform matrix

| Platform | Status | Evidence boundary |
|---|---|---|
| Linux | Validated | Pinned development container; remote consumer resolution, debug/release linked execution, and the hardware-free Core Embedded Swift gate |
| macOS | Best effort | The manual macOS oracle procedure is available in [testing](testing.md#manual-macos-oracle); current consumer evidence is Linux-only |
| iOS | Experimental, unvalidated | No dedicated simulator or device consumer validation is claimed; see the [support matrix](SUPPORT_MATRIX.md#platforms) |

Do not treat a successful Linux run as platform evidence for macOS or iOS.
Ordinary consumer validation and Core Embedded Swift checks never probe,
reserve, flash, or request hardware access.
