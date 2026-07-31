# External package consumer validation

## Result

Both `Axoloty` and `AxolotyWire` are consumable as external Swift Package
Manager dependencies. Clean temporary packages resolve, build (debug and
release), and execute minimal API usage.

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
