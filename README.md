# Axoloty

[![Swift
version](https://img.shields.io/badge/swift-6.3)](https://developer.apple.com/swift/)
[![License:
MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## About Axoloty

__Axoloty__ is a Swift framework for building distributed, collaborative IoT
applications out of loosely coupled, decentralized components called *agents*.
Agents communicate with each other in (soft) real time over a publish-subscribe
messaging backbone (MQTT), and can run on IoT devices, mobile devices, in
microservices, or in cloud and backend services.

Axoloty provides a production-ready application and communication layer
foundation for collaborative IoT prosumer scenarios where smart agents act in
an autonomous, collaborative, and ad-hoc fashion. Its key properties include:

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
* and a structured logging facade backed by [swift-log](https://github.com/apple/swift-log).

Axoloty is a modernized fork of
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift) and follows its
own direction documented in [ROADMAP.md](./docs/ROADMAP.md). For an explicit
comparison against CoatyJS and legacy CoatySwift, see
[FEATURE_MATRIX.md](./docs/FEATURE_MATRIX.md).

## Getting started

Axoloty is distributed via Swift Package Manager only.

It is compatible with the following deployment targets:

| Deployment Target | Compatibility |
| ----------------- | ------------- |
| iOS               | 12.0+         |
| macOS             | 10.14+        |
| Linux             | Yes (containerized) |

See [ROADMAP.md](./docs/ROADMAP.md) for the current project direction.

### Swift Package Manager

To use Axoloty with Swift Package Manager you need XCode 11.0 or higher. The
Swift Package Manager is a package manager integrated into the swift compiler.

Once you have your Swift package set up, add Axoloty by modifying the
`dependencies` attribute in your `Package.swift` file.

```swift
dependencies: [
    .package(url: "https://github.com/phynics/coaty-swift", from: "2.4.0"),
]
```

API documentation is built from in-source DocC comments and published to
GitHub Pages: <https://phynics.github.io/axoloty/>.

## Examples

Examples are available in the original
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift) repository and
the related [coaty-examples](https://github.com/coatyio/coaty-examples) repo.

## Building & Testing

Building and testing Axoloty is container-based (via
[podman](https://podman.io)), so no local Swift toolchain installation is
required. The devcontainer is the normal long-lived environment; Podman or
Docker disposable containers remain the fallback when working outside it. This
also works around dynamic-linking failures with the native
Swift toolchain on the NixOS development machine used for this project:

```sh
make worktree-bootstrap  # resolve dependencies into the shared SwiftPM cache
make build   # build the package inside the container
make test    # run the test suite inside the container
make ci      # support checks plus one coverage-enabled Swift test pass
```

Each worktree owns its `.build` compiler output. SwiftPM downloads are shared
through `SPM_CACHE_DIR`, which defaults to a toolchain-specific cache under
`~/.cache/coaty-swift/swiftpm/`. Override `BUILD_DIR` or `SPM_CACHE_DIR` when a
different disk or CI cache path is needed. `make worktree-warm` is an optional
explicit prebuild; bootstrap itself resolves dependencies but does not compile.

Coverage reports are written to `.testing/coverage/`. The aggregate ratchet is
enforced, while changed-line coverage is displayed in CI summaries and native
workflow warnings for information only.

See [AGENTS.md](./AGENTS.md) for the full set of Makefile targets (including
`make shell` and `make docs`) and how the containerized flow is set up.

## Contributing

For agent- and maintainer-facing conventions used in this fork (build/test
commands, workflow, coding conventions, git identity rules), see
[AGENTS.md](./AGENTS.md). For the modernization plan, see
[ROADMAP.md](./docs/ROADMAP.md).

## License

Axoloty is a fork of [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift),
which originated at Siemens AG and is licensed under the
[MIT License](https://opensource.org/licenses/MIT). All code and documentation
in this repository is distributed under that same MIT License.

The following vendored software is included in this repository:

-   AnyCodable [MIT
    License](https://github.com/Flight-School/AnyCodable/blob/master/LICENSE)
