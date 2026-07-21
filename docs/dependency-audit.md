# Dependency Audit

Audit of every package dependency declared in `Package.swift`, reviewed for
freshness, license compatibility, platform support, and necessity against the
modernization roadmap. Latest-release versions were fetched from each
dependency's GitHub releases page on 2026-07-15.

## Summary

| Dependency | Declared | Latest | Resolved | License | Purpose | Status |
|---|---|---|---|---|---|---|
| mqtt-nio | `from: 2.13.0` | 2.13.0 | 2.13.0 | Apache-2.0 | MQTT 5 transport client backing `CommunicationClient` | current |
| swift-nio | `from: 2.101.2` | 2.101.2 | 2.101.2 | Apache-2.0 | Async network primitives used transitively by mqtt-nio and our TLS code | current |
| swift-nio-ssl | `from: 2.37.1` | 2.37.1 | 2.37.1 | Apache-2.0 | TLS on Linux (non-Apple platforms); Apple platforms use Network.framework via NIOTransportServices | current |
| swift-log | `from: 1.14.0` | 1.14.0 | 1.14.0 | Apache-2.0 | Structured logging facade backing `LogManager` | current |
| ErrorKit | `exact: 1.2.1` | 1.2.1 | 1.2.1 | MIT | `Throwable` error policy and user-facing error formatting (`AxolotyError`) | current; pinned exact |
| swift-docc-plugin | `from: 1.5.0` | 1.5.0 | 1.5.0 | Apache-2.0 | Provides `swift package generate-documentation` used by `make docs` | current; build-tool only |

All seven direct dependencies are resolved at their latest published release,
so no version bump is required for freshness. Every dependency is licensed under
Apache-2.0 or MIT, both permissive and compatible with the project's MIT
license. Transitive dependencies recorded in `Package.resolved`
(swift-crypto, swift-asn1, swift-collections, swift-atomics,
swift-nio-transport-services, swift-system, swift-docc-symbolkit) are brought
in by the SwiftNIO family and swift-docc-plugin and inherit Apache-2.0.

## Per-dependency notes

### mqtt-nio (`2.13.0`, Apache-2.0)

Imported only by `Source/Communication/Client/MQTTNIOClient.swift`, which wraps
it as the concrete `CommunicationClient`. It is the sole MQTT transport and
defines the wire layer exercised by the compatibility suite. It must remain
compatible with the Swift 6.3 container toolchain and the WASI feasibility
target (T-030). The `2.13.0` release adds Android support and is the current
latest; no action needed. Keep as a `from:` range.

### swift-nio (`2.101.2`, Apache-2.0)

Imported directly in `MQTTNIOClient.swift` (`NIO`) and required transitively by
mqtt-nio. Direct use is limited to buffer/event-loop primitives in the MQTT
client. No direct API surface beyond the client. Current at latest. No action
needed.

### swift-nio-ssl (`2.37.1`, Apache-2.0)

Imported conditionally in `MQTTNIOClient.swift` via
`.when(platforms: [.linux])` in `Package.swift`; on Apple platforms TLS goes
through `NIOTransportServices`/Network.framework instead. The `2.37.1` release
enables `x25519_MLKEM768` by default and is current at latest. No action
needed. The platform-conditional linkage is the correct pattern and should be
preserved.

### swift-log (`1.14.0`, Apache-2.0)

Imported by `LogManager` and `MQTTNIOClient`. Provides the `Logger` facade.
The `1.14.0` release adds task-local logger support. The ErrorKit policy
(T-025/T-031) routes user-facing error text through ErrorKit rather than
duplicating formatting at the logging boundary; swift-log remains the
logging backend. Current at latest. No action needed.

### ErrorKit (`1.2.1` exact, MIT)

Imported by `Source/Common/AxolotyError.swift`, which conforms `AxolotyError`
to `Throwable` with a tested `userFriendlyMessage`. Pinned with `exact:`
rather than `from:` to keep the error-policy contract reproducible, as
recommended by T-025. Current at latest (1.2.1 adds `Logger` convenience
overloads). No action needed. Relaxing the `exact:` pin to a `from:` range is
possible once the policy surface is stable, but is out of scope here.

### swift-docc-plugin (`1.5.0`, Apache-2.0)

A build-time-only command plugin providing `swift package
generate-documentation`, invoked by `make docs`. It is not linked into the
shipping target. Current at latest (`1.5.0` extends snippet extraction). No
action needed.

## Vendored code

No vendored third-party source exists under `Source/`. The previously vendored
fork of Flight-School/AnyCodable was removed in #110, replaced by the internal
`JSONValue` type and raw JSON `String` storage across the snapshot, event, and
model layers. A CI check (`make test-no-anycodable`) enforces that `AnyCodable`
does not reappear in `Source/`.

## Actionable recommendations

1. **No version bumps required.** All six runtime dependencies and the docc
   plugin are resolved at their latest releases. Future updates flow
   automatically through the `from:` ranges; only ErrorKit's `exact:` pin
   requires an intentional bump.

## Roadmap alignment

This audit does not conflict with any in-flight ticket. It confirms that
mqtt-nio, swift-nio, swift-nio-ssl, and swift-log are current and remain
compatible with the container toolchain and the WASI feasibility spike
(T-030). RxSwift removal is complete (T-028). AnyCodable removal is complete
(#110, superseding T-036).
