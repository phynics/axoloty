# External package consumer validation

## Result

Both `Axoloty` and `AxolotyWire` are published products of the root package.
`Tests/Support/check-axoloty-semver-consumer.sh` creates a clean consumer with
a `from:` semantic-version requirement, then builds both product imports in
debug and release. By default, the gate creates a temporary bare `file://`
remote and synthetic semver tag so pre-release checkpoints test the stable
version topology. Set `AXOLOTY_CONSUMER_LOCAL=0` together with
`AXOLOTY_CONSUMER_REPOSITORY_URL` and `AXOLOTY_CONSUMER_VERSION` to validate a
published release.

The wire boundary pins `phynics/swift-json` exactly at `2.5.3`; that release
is published from commit `ec81216be5bbe2f02f45831d05256de2af452be8`, so
the checked-in root `Package.resolved` can be regenerated remotely.

## Axoloty consumer

**Package dependency (standalone development fixture only):**
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

## AxolotyWire consumer

**Package dependency:**
```swift
.package(path: "/path/to/axoloty/Packages/AxolotyWire")
// Target:
.product(name: "AxolotyWire", package: "AxolotyWire")
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

**Dependency closure:**
```
axolotywire
```
No host-only dependencies (MQTTNIO, SwiftNIO, NIOSSL, Foundation, swift-log,
ErrorKit, IkigaJSON) are present. `AxolotyWire` is fully isolated.

## Product and module names

| Product | Package | Module | Correct |
|---|---|---|---|
| `Axoloty` | `workspace` (path) / `Axoloty` (URL) | `Axoloty` | ✅ |
| `AxolotyWire` | `AxolotyWire` | `AxolotyWire` | ✅ |

## Platform validation

- **Linux (containerized):** ✅ Validated — both consumers build and run.
- **macOS:** Not validated on this host (Linux only). The package declares
  macOS 26.0+ and uses NIOTransportServices (Network.framework) on Apple
  platforms. Manual macOS oracle verification is documented in
  `Tests/TESTING.md`.
- **iOS:** Not validated. Declared in Package.swift (iOS 26.0+) and shares
  the Apple-platform code path with macOS. Zero dedicated test coverage.
