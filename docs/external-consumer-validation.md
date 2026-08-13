# External package consumer validation

## Result

Axoloty supports two distinct wire-consumer topologies. The root package
publishes an `AxolotyWire` product for consumers that already use the root
package. The standalone `Packages/AxolotyWire` package is the supported
acquisition boundary when independent package resolution is required.

`Tests/Support/check-axoloty-wire-distribution.sh` validates both modes by
checking resolution separately from target build/link/runtime behavior.
`Tests/Support/check-axoloty-semver-consumer.sh` additionally validates the
published root-package product topology with a `from:` semantic-version
requirement. By default, that gate creates a temporary bare `file://` remote
and synthetic semver tag so pre-release checkpoints test the stable version
topology. Set `AXOLOTY_CONSUMER_LOCAL=0` together with
`AXOLOTY_CONSUMER_REPOSITORY_URL` and `AXOLOTY_CONSUMER_VERSION` to validate a
published release.

The wire boundary pins `phynics/swift-json` exactly at `2.5.3`; that release
is published from commit `ec81216be5bbe2f02f45831d05256de2af452be8`, so
the checked-in root `Package.resolved` can be regenerated remotely.

## Axoloty consumer

**Package dependency:**
```swift
.package(path: "/path/to/axoloty")
// Target:
.product(name: "Axoloty", package: "workspace")
```

**Minimal usage:**
```swift
import Axoloty
let identity = Identity(name: "external-consumer")
let error = AxolotyError.runtime(code: .notStarted, reason: "anchor")
```

**Build results:**
- Debug build: ✅ passed
- Release build: ✅ passed
- Runtime: ✅ `AXOLOTY_EXTERNAL_CONSUMER_OK: Identity external consumer anchor`

## Root-package AxolotyWire consumer

**Package dependency:**
```swift
.package(path: "/path/to/axoloty")
// Target:
.product(name: "AxolotyWire", package: "workspace")
```

**Minimal usage:**
```swift
import AxolotyWire
let reader = WireReader(bytes: base, length: count)
let object = reader.readRaw("object")
```

**Build results:**
- Debug build: ✅ passed
- Release build: ✅ passed
- Runtime: ✅ `AXOLOTY_WIRE_EXTERNAL_CONSUMER_OK: found`

**Topology:** SwiftPM resolves the root package's complete dependency graph
before selecting the wire product. Building this target does not compile or
link host runtime targets, but resolution still includes the root host graph.

## Standalone AxolotyWire consumer

**Package dependency:**
```swift
.package(path: "/path/to/axoloty/Packages/AxolotyWire")
// Target:
.product(name: "AxolotyWire", package: "AxolotyWire")
```

**Minimal usage:**
```swift
import AxolotyWire
print(UUID16.zero)
```

**Build results:**
- Debug build: ✅ passed
- Linked executable: ✅ passed
- Runtime: ✅ `AXOLOTY_WIRE_STANDALONE_CONSUMER_OK`

**Dependency closure:**
```
AxolotyWire -> swift-json/IkigaJSONCore
```
The standalone package may resolve `swift-nio` as a transitive dependency of
`swift-json`, but it must not build or link NIO targets. Host-only packages
(MQTTNIO, NIOSSL, NIOTransportServices, swift-log, ErrorKit, and the host
`IkigaJSON` product) are absent. The target is Foundation-free and isolated
from the host runtime, rather than dependency-free at package resolution.

## Product and module names

| Product | Package | Module | Correct |
|---|---|---|---|
| `Axoloty` | `workspace` (path) / `Axoloty` (URL) | `Axoloty` | ✅ |
| `AxolotyWire` (root product) | `axoloty` | `AxolotyWire` | ✅ |
| `AxolotyWire` (standalone) | `AxolotyWire` | `AxolotyWire` | ✅ |

## Platform validation

- **Linux (containerized):** ✅ Validated — both consumers build and run.
- **macOS:** Not validated on this host (Linux only). The package declares
  macOS 26.0+ and uses NIOTransportServices (Network.framework) on Apple
  platforms. Manual macOS oracle verification is documented in
  `Tests/TESTING.md`.
- **iOS:** Not validated. Declared in Package.swift (iOS 26.0+) and shares
  the Apple-platform code path with macOS. Zero dedicated test coverage.
