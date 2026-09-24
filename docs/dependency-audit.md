# Dependency Audit

Audit of every package dependency declared in `Package.swift`, reviewed for
freshness, license compatibility, platform support, and necessity against the
modernization roadmap. Latest-release versions were fetched from each
dependency's GitHub releases page on 2026-07-15.

## Summary

| Dependency | Declared | Latest | Resolved | License | Purpose | Status |
|---|---|---|---|---|---|---|
| mqtt-nio | `from: 2.13.0` | 2.13.0 | 2.13.0 | Apache-2.0 | MQTT 5 transport client backing `AxolotyRuntime` | current |
| swift-nio | `from: 2.101.2` | 2.101.2 | 2.101.2 | Apache-2.0 | Async network primitives used transitively by mqtt-nio and our TLS code | current |
| swift-nio-ssl | `from: 2.37.1` | 2.37.1 | 2.37.1 | Apache-2.0 | TLS on Linux (non-Apple platforms); Apple platforms use Network.framework via NIOTransportServices | current |
| swift-log | `from: 1.14.0` | 1.14.0 | 1.14.0 | Apache-2.0 | Structured diagnostics logging for the Axoloty MCP server | current; MCP-only |
| ErrorKit | `exact: 1.2.1` | 1.2.1 | 1.2.1 | MIT | `Throwable` error policy and user-facing error formatting (`AxolotyError`) | current; pinned exact |
| swift-json (phynics fork) | `exact: 2.5.3` | n/a (fork) | 2.5.3 | MIT | `_JSONCore` structural parser behind `AxolotyWire` (product `IkigaJSONCore`) | pinned exact; see notes |
| swift-syntax | `exact: 604.0.0` | 604.0.0 | 604.0.0 | Apache-2.0 | Swift macro implementation and macro-test support | pinned to Swift 6.4 |
| swift-docc-plugin | `from: 1.5.0` | 1.5.0 | 1.5.0 | Apache-2.0 | Provides `swift package generate-documentation` used by `make docs` | current; build-tool only |

The audited direct dependencies are current. SwiftSyntax is pinned to the
release that matches the Swift 6.4 compiler. Its 6.4 macro-test support records
failures through Swift Testing instead of routing them through XCTest. Every
dependency is licensed under Apache-2.0 or MIT, both compatible with the
project's MIT license. Transitive dependencies recorded in `Package.resolved`
(swift-crypto, swift-asn1, swift-collections, swift-atomics,
swift-nio-transport-services, swift-system, swift-docc-symbolkit) are brought
in by the SwiftNIO family and swift-docc-plugin and inherit Apache-2.0.

## Per-dependency notes

### mqtt-nio (`2.13.0`, Apache-2.0)

Imported only by `Packages/AxolotyMQTT/Sources/AxolotyMQTT/RuntimeMQTTClient.swift`, which the
`MQTTBinding` owns for the host runtime. It is the sole MQTT transport and
defines the wire path exercised by the compatibility suite. It must remain
compatible with the Swift 6.4 container toolchain and the WASI feasibility
target (T-030). The `2.13.0` release adds Android support and is the current
latest; no action needed. Keep as a `from:` range.

### swift-nio (`2.101.2`, Apache-2.0)

Imported directly in `Packages/AxolotyMQTT/Sources/AxolotyMQTT/RuntimeMQTTClient.swift` (`NIO`) and
required transitively by mqtt-nio. Direct use is limited to buffer and event
loop primitives in the MQTT client. No direct API surface beyond the client.
Current at latest. No action needed.

### swift-nio-ssl (`2.37.1`, Apache-2.0)

Imported conditionally in `Packages/AxolotyMQTT/Sources/AxolotyMQTT/RuntimeMQTTClient.swift` via
`.when(platforms: [.linux])` in `Package.swift`; on Apple platforms TLS goes
through `NIOTransportServices`/Network.framework instead. The `2.37.1` release
enables `x25519_MLKEM768` by default and is current at latest. No action
needed. The platform-conditional linkage is the correct pattern and should be
preserved.

### swift-log (`1.14.0`, Apache-2.0)

Imported by `Apps/AxolotyMCP/AxolotyMCPServer.swift`, which uses the
`Logger` facade for encoding-failure diagnostics. The root `Axoloty` target
does not declare `swift-log`; applications choose their own logging bootstrap
for runtime diagnostics. The `1.14.0` release adds task-local logger support.
The ErrorKit policy (T-025/T-031) routes user-facing error text through
ErrorKit rather than duplicating formatting at the logging boundary. Current
at latest. No action needed.

### ErrorKit (`1.2.1` exact, MIT)

Imported by `Source/Common/AxolotyError.swift`, which conforms `AxolotyError`
to `Throwable` with a tested `userFriendlyMessage`. Pinned with `exact:`
rather than `from:` to keep the error-policy contract reproducible, as
recommended by T-025. Current at latest (1.2.1 adds `Logger` convenience
overloads). No action needed. Relaxing the `exact:` pin to a `from:` range is
possible once the policy surface is stable, but is out of scope here.

### swift-json (`2.5.3` exact, phynics fork, MIT)

`AxolotyWire` depends on the `IkigaJSONCore` product, which exposes the
Foundation-free `_JSONCore` target, and is the only target that does. Upstream
swift-json declared no such product for Swift 6.2+
([orlandos-nl/swift-json#63](https://github.com/orlandos-nl/swift-json/issues/63));
the minimal manifest fix was submitted as
[orlandos-nl/swift-json#68](https://github.com/orlandos-nl/swift-json/pull/68).
Until that ships in an upstream release, Axoloty pins the
`phynics/swift-json` fork that exposes the product; the fork is meant to carry
only that manifest correction. Vendoring parser sources was considered and rejected
(#394).

swift-json declares swift-nio as an unconditional package dependency, so
SwiftPM resolves swift-nio and its transitives even for a portable consumer.
That cost is accepted because it is resolution-only: no NIO target is built or
linked into `AxolotyWire` (module policy forbids the import), and
`_JSONCore` compiles without Foundation or NIO.

Before updating the pin, review upstream source and license changes, then
confirm that `make check-embedded-core-consumer` still compiles and links
`_JSONCore` for Embedded Swift. Reject the update if NIO begins building or
linking into `AxolotyWire`, or if `_JSONCore` stops compiling on host or
Embedded Swift. The one-off probes behind this decision (#394, #395) were
removed once the required Embedded Swift gate took over the check; they
remain in git history.

### swift-docc-plugin (`1.5.0`, Apache-2.0)

A build-time-only command plugin providing `swift package
generate-documentation`, invoked by `make docs`. It is not linked into the
shipping target. Current at latest (`1.5.0` extends snippet extraction). No
action needed.

### swift-syntax (`604.0.0`, Apache-2.0)

The macro implementation and test targets use SwiftSyntax. Keep its exact pin
aligned with the compiler toolchain. SwiftSyntax 604 adds Swift Testing failure
reporting to `SwiftSyntaxMacrosTestSupport`, which the schema macro tests use.
SwiftSyntax 603 routed those failures through XCTest and caused every macro
expansion assertion to fail under the Swift 6.4 test runner.

## Vendored code

No vendored third-party source exists under `Source/`. The previously vendored
fork of Flight-School/AnyCodable was removed in #110, replaced by the internal
`JSONValue` type and raw JSON `String` storage across the snapshot, event, and
model layers. A CI check (`make test-no-anycodable`) enforces that `AnyCodable`
does not reappear in `Source/`.

## Actionable recommendations

1. **Keep the SwiftSyntax pin aligned with the compiler.** The `from:` ranges
   resolve to current releases. ErrorKit and SwiftSyntax use exact pins and
   require intentional updates.

## Roadmap alignment

This audit does not conflict with any in-flight ticket. It confirms that
mqtt-nio, swift-nio, swift-nio-ssl, and swift-log are current and remain
compatible with the container toolchain and the WASI feasibility spike
(T-030). `swift-log` is limited to the MCP tool target; the G4 runtime exposes
bounded diagnostics instead of a package-owned logging facade. RxSwift removal
is complete (T-028). AnyCodable removal is complete (#110, superseding T-036).
