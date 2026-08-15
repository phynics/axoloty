

<p align="center">
  <img src="docs/assets/axoloty-wordmark.svg" alt="Axoloty — IoT application framework" width="480">
</p>

[![Swift
version](https://img.shields.io/badge/swift-6.3-%23F05138?logo=swift)](https://developer.apple.com/swift/)
[![License:
MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

> **Development checkpoint.** Axoloty 0.4 is a development checkpoint, not
> a stable release. Public APIs may continue to change before 1.0.

## About Axoloty

__Axoloty__ is a Swift framework for building distributed, collaborative IoT
applications out of loosely coupled, decentralized components called *agents*.
Agents communicate with each other in (soft) real time over a publish-subscribe
messaging backbone (MQTT), and can run on IoT devices, mobile devices, in
microservices, or in cloud and backend services.

Axoloty provides an application and communication layer foundation for
collaborative IoT prosumer scenarios where smart agents act in an autonomous,
collaborative, and ad-hoc fashion. Its key properties include:

* a lightweight, modular, object-oriented software architecture favoring a
  resource-oriented and declarative programming style,
* an IoC container with controller-based dependency injection and lifecycle
  management as the entry point for any Axoloty application,
* standardized event-based communication patterns — Advertise / Deadvertise,
  Discover / Resolve, Query / Retrieve, Update / Complete, Channel, and
  Call / Return — on top of [MQTT](https://mqtt.org),
* an IO routing model for routing streams of sensor data between sources and
  actors with pluggable backpressure strategies,
* a platform-agnostic, extensible object model to discover, distribute, share,
  query, and persist hierarchically typed data,
* structured error handling through [ErrorKit](https://github.com/FlineDev/ErrorKit),
  with `AxolotyError` as the package's `Throwable` base error type,
* a structured logging facade backed by [swift-log](https://github.com/apple/swift-log),
* a Foundation-free `AxolotyWire` module with a separately resolvable
  standalone package boundary for embedded targets,
* and an ESP32-C6 embedded proof in Embedded Swift.

Axoloty is a modernized fork of
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift) and follows its
own direction documented in [ROADMAP.md](./docs/ROADMAP.md). For an explicit
comparison against CoatyJS and legacy CoatySwift, see
[FEATURE_MATRIX.md](./docs/FEATURE_MATRIX.md). For support levels per
capability, see [SUPPORT_MATRIX.md](./docs/SUPPORT_MATRIX.md).

## Getting started

Axoloty is distributed via Swift Package Manager only.

| Deployment Target | Compatibility |
| ----------------- | ------------- |
| iOS               | 26.0+         |
| macOS             | 26.0+         |
| Linux             | Yes (containerized) |
| ESP32-C6          | Embedded Swift (Advertise/Deadvertise, Discover/Resolve) |

### Swift Package Manager

Add Axoloty to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/phynics/axoloty", from: "0.4.0"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "Axoloty", package: "axoloty"),
        ]
    ),
]
```

For a wire target in a consumer that already resolves the root package:

```swift
dependencies: [
    .package(url: "https://github.com/phynics/axoloty", from: "0.4.0"),
],
targets: [
    .executableTarget(
        name: "WireApp",
        dependencies: [
            .product(name: "AxolotyWire", package: "axoloty"),
        ]
    ),
]
```

Selecting `AxolotyWire` narrows compilation and linking to the wire target, but
the root package still resolves its complete host dependency graph. For
independent wire-only package resolution, use the standalone package at
`Packages/AxolotyWire` as documented in
[`docs/external-consumer-validation.md`](docs/external-consumer-validation.md).

### Minimal host example

```swift
import Axoloty

@MainActor
func runAgent() async throws {
    let configuration = try Configuration.build { builder in
        builder.common = CommonOptions(agentIdentity: ["name": "my-agent"])
        builder.communication = CommunicationOptions(
            namespace: "my-app",
            mqttClientOptions: MQTTClientOptions(host: "localhost", port: 1883),
            shouldAutoStart: false
        )
    }
    let components = Components(controllers: [:], objectTypes: [])
    let container = try Container.resolve(
        components: components,
        configuration: configuration
    )
    defer { container.shutdown() }
    guard let manager = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(
            option: "communicationManager",
            reason: "was not initialized"
        )
    }

    let stream = try await manager.observeAdvertiseStream(
        withObjectType: Identity.objectType
    )
    var iterator = stream.makeAsyncIterator()
    try await container.startAndWaitUntilReady()
    manager.publishAdvertise(try AdvertiseEvent.with(object: Identity(name: "my-agent")))

    _ = await iterator.next()
}
```

Call `runAgent()` from your application lifecycle when the MQTT broker is
available. The `shouldAutoStart: false` setting keeps startup explicit.

### Minimal AxolotyWire example

```swift
import AxolotyWire

let payload = #"{"object":{"objectId":"00000000-0000-4000-8000-000000000001"}}"#
let bytes = Array(payload.utf8)
let result = bytes.withUnsafeBufferPointer { buffer -> String in
    guard let base = buffer.baseAddress else { return "nil" }
    let reader = WireReader(bytes: base, length: buffer.count)
    let object = reader.readRaw("object")
    return object != nil ? "found" : "nil"
}
print("Result: \(result)")
```

### Embedded limitations

The ESP32-C6 embedded target supports only Advertise/Deadvertise and
Discover/Resolve. It uses a static composition model (no dynamic
registration) with bounded capacities:

- Max topic length: 128 bytes
- Max payload size: 512 bytes
- Max subscribers: 8
- Max family entries: 16
- QoS: 0 only
- TLS: not supported
- No IO routing, Channel, Query/Retrieve, Update/Complete, or Call/Return

See [docs/embedded-toolchain.md](./docs/embedded-toolchain.md) for toolchain
setup and [SUPPORT_MATRIX.md](./docs/SUPPORT_MATRIX.md) for the full
capability matrix.

API documentation is built from in-source DocC comments and published to
GitHub Pages: <https://phynics.github.io/axoloty/documentation/Axoloty/>.

## Building & Testing

The Swift `axoloty-tool` executable is the orchestration control plane. On
Linux, the pinned container provides a stable launcher that builds the
mounted-worktree product in the worktree-specific cache via the lightweight
Makefile and `.devcontainer/run.sh`.
macOS runs the same offline plan with native Swift:

```sh
make worktree-bootstrap  # resolve dependencies into the shared SwiftPM cache
make check               # Linux: offline host, wire, and embedded checks
make hardware-check      # run or skip the sporadically attached ESP32-C6
make hardware-require    # require the ESP32-C6 for an explicit release gate
make release-fixture-bundle   # bundle committed wire fixtures offline (not fresh wire evidence)

# local services
make serve-mqtt
make serve-mcp SERVE_MCP_ARGS='--transport http'
make serve-dev

# macOS
swift run --package-path Tools axoloty-tool check
```

See [docs/services.md](./docs/services.md) for MQTT/MCP installation and
transport details.

### MQTT object inspector

`axoloty-inspect` connects to a live MQTT broker and inspects Coaty objects
without writing a custom agent — passive catalogue (`catalog`) or active
discovery (`discover`):

```sh
swift run --package-path Tools axoloty-inspect catalog --duration 10s
swift run --package-path Tools axoloty-inspect discover --core-type Identity
```

See [docs/inspector.md](./docs/inspector.md) for the full reference.

For this checkpoint's changes and source-breaking migration, see
[0.4-RELEASE-NOTES.md](./docs/0.4-RELEASE-NOTES.md). For migrating from legacy
CoatySwift, see [0.2-MIGRATION.md](./docs/0.2-MIGRATION.md).

## Contributing

For agent- and maintainer-facing conventions used in this fork (build/test
commands, workflow, coding conventions, git identity rules), see
[AGENTS.md](./AGENTS.md). For the roadmap, see
[ROADMAP.md](./docs/ROADMAP.md).

### Swift engineering conventions

- **Strict concurrency:** Axoloty builds in Swift 6 language mode. Preserve
  actor and global-actor isolation, make values and closures `Sendable` when
  they cross concurrency boundaries, and use `@unchecked Sendable` only for a
  demonstrably synchronized implementation.
- **Scoped borrowing:** Wire-codec views such as `BorrowedMessage`, `ByteSlice`,
  and `TopicView` borrow externally owned bytes for synchronous, zero-copy
  work. Keep borrowed values inside their callback or buffer lifetime; validate
  untrusted input first, and copy data before returning, awaiting, creating a
  task, or crossing an isolation boundary. Do not retain or send borrowed views.
- **Testing:** Use Swift Testing (`@Test`, `#expect`, `#require`, and
  `Issue.record`), with explicit timeouts or synchronization for asynchronous
  work; do not add XCTest.
- **Logging:** Use `LogManager.logger(.subsystem)` and structured `metadata:`
  for dynamic values; see [AGENTS.md](./AGENTS.md) for levels, error chains,
  and correlation IDs.

## License

Axoloty is a fork of [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift),
which originated at Siemens AG and is licensed under the
[MIT License](https://opensource.org/licenses/MIT). All code and documentation
in this repository is distributed under that same MIT License.
