

<p align="center">
  <img src="docs/assets/axoloty-wordmark.svg" alt="Axoloty — IoT application framework" width="480">
</p>

[![Swift
version](https://img.shields.io/badge/swift-6.3-%23F05138?logo=swift)](https://developer.apple.com/swift/)
[![License:
MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

> **Development checkpoint.** [`VERSION`](./VERSION) identifies the current
> published release (`0.6.2`). Axoloty is not API-stable. The 0.6 line aligns
> the host and Embedded Swift runtimes around the shared wire and protocol path,
> with typed IO and optional products from G5.

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
* an immutable runtime definition and single-use `AxolotyRuntime` lifecycle,
* standardized event-based communication patterns — Advertise / Deadvertise,
  Discover / Resolve, Query / Retrieve, Update / Complete, Channel, and
  Call / Return — on top of [MQTT](https://mqtt.org),
* a fixed synchronous `AxolotyStaticRuntime` profile for Embedded Swift,
* a platform-agnostic, extensible object model to discover, distribute, share,
  query, and persist hierarchically typed data,
* structured error handling through [ErrorKit](https://github.com/FlineDev/ErrorKit),
  with `AxolotyError` as the package's `Throwable` base error type,
* bounded runtime diagnostics that applications can forward to their own
  logger,
* a Foundation-free `AxolotyWire` module with a separately resolvable
  standalone package boundary for embedded targets,
* a Foundation-free `AxolotyProtocol` foundation package with the shared
  fixed-inline processor, bounded request state, and borrowed/owned actions,
* and an ESP32-C6 embedded proof in Embedded Swift.

Axoloty is a modernized fork of
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift) and follows its
own direction documented in [ROADMAP.md](./docs/ROADMAP.md). The accepted 0.6
boundaries and transition state are documented in
[ARCHITECTURE.md](./ARCHITECTURE.md). For an explicit
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
    .package(url: "https://github.com/phynics/axoloty", from: "0.6.2"),
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
    .package(url: "https://github.com/phynics/axoloty", from: "0.6.2"),
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

The checked-in, compilable version is [`Examples/Sources/HostRuntimeExample/main.swift`](./Examples/Sources/HostRuntimeExample/main.swift); run it with
`swift run --package-path Examples HostRuntimeExample`.

```swift
import Axoloty

func runAgent() async throws {
    let identity = try RuntimeIdentity(id: .zero, name: "my-agent")
    var builder = try RuntimeBuilder(identity: identity, namespace: "my-app")
    _ = try builder.events(
        matching: .family(.advertise),
        buffering: .fail(capacity: 64)
    )
    let definition = try builder.finish()
    let runtime = AxolotyRuntime(
        definition: definition,
        transport: try MQTTBinding(configuration: .init(host: "localhost", port: 1883))
    )
    try await runtime.run()
}
```

Call `runAgent()` from your application lifecycle when the MQTT broker is
available. Startup is explicit: `run()` is the operation that starts and owns
the runtime lifecycle.

### Minimal AxolotyWire example

The corresponding checked-in source is [`Examples/Sources/WireExample/main.swift`](./Examples/Sources/WireExample/main.swift); run it with
`swift run --package-path Examples WireExample`.

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

- Axoloty max topic length: 256 bytes. MQTT and Coaty do not impose this
  limit, so longer topics are an intentional compatibility divergence.
- Advertised external IO routes also reject control characters, quotation
  marks, and backslashes to keep their encoded metadata statically bounded.
- Axoloty max payload size: 2,048 bytes. Coaty itself does not impose this
  limit, so messages above 2 KiB are an intentional compatibility divergence.
- Static runtimes may select a smaller compile-time payload capacity (for
  example, `StaticRuntime<16, 128>`); 2,048 bytes remains the sealed maximum.
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
make verify              # Linux: canonical ordinary verification
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

For the current release's changes, see
[0.6.2 release notes](./docs/releases/0.6.2.md). For migrating from legacy
CoatySwift, see [the 0.2 migration guide](./docs/migration/from-coatyswift-to-0.2.md).
For the 0.7 runtime-registration migration, see
[the 0.6-to-0.7 guide](./docs/migration/from-0.6-to-0.7.md).

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
- **Diagnostics:** Use `RuntimeDiagnostics` for bounded runtime counters and
  streams. Applications choose their own [swift-log](https://github.com/apple/swift-log)
  bootstrap and filtering policy; see [AGENTS.md](./AGENTS.md) for error
  chains and correlation IDs.

## License

Axoloty is a fork of [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift),
which originated at Siemens AG and is licensed under the
[MIT License](https://opensource.org/licenses/MIT). All code and documentation
in this repository is distributed under that same MIT License.
