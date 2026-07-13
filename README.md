# Axoloty

[![Swift
version](https://img.shields.io/badge/swift-5.3%2B-FF4029.svg)](https://developer.apple.com/swift/)
[![License:
MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

## About Axoloty

[phynics/coaty-swift](https://github.com/phynics/coaty-swift) is a fork of
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift).

This repository follows its own [ROADMAP.md](./ROADMAP.md). If you're looking
for the original project and its documentation, use
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift).

See [FEATURE_MATRIX.md](./FEATURE_MATRIX.md) for an explicit comparison of
CoatyJS, legacy CoatySwift, and Axoloty. The Swift implementations have never
provided every CoatyJS module, and the matrix keeps API presence separate from
verified wire compatibility.

__Axoloty__ is a [Coaty](https://coaty.io/) implementation written in Swift.

## What is Coaty

Using the Coaty [koʊti] framework as a middleware, you can build distributed
applications out of decentrally organized application components, so called
*Coaty agents*, which are loosely coupled and communicate with each other in
(soft) real-time. The main focus is on IoT prosumer scenarios where smart agents
act in an autonomous, collaborative, and ad-hoc fashion. Coaty agents can run on
IoT devices, mobile devices, in microservices, cloud or backend services.

Coaty provides a production-ready application and communication layer foundation
for building collaborative IoT applications in an easy-to-use yet powerful and
efficient way. The key properties of the Axoloty framework include:

* a lightweight and modular object-oriented software architecture favoring a
  resource-oriented and declarative programming style,
* standardized event based communication patterns on top of an open
  publish-subscribe messaging protocol (currently [MQTT](https://mqtt.org)),
* and a platform-agnostic, extensible object model to discover, distribute,
  share, query, and persist hierarchically typed data.

## Upstream Reference

The original CoatySwift repository is [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift).

## Getting started

Axoloty is distributed via Swift Package Manager only.

It is compatible with the following deployment targets:

| Deployment Target | Compatibility |
| ----------------- | ------------- |
| iOS               | 10.0+         |
| macOS             | 10.13+        |

See [ROADMAP.md](./ROADMAP.md) for the current project direction.

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

## Examples

Examples are available in the original
[coatyio/coaty-swift](https://github.com/coatyio/coaty-swift) repository and
the related [coaty-examples](https://github.com/coatyio/coaty-examples) repo.

## Building & Testing

Building and testing Axoloty is container-based (via
[podman](https://podman.io)), so no local Swift toolchain installation is
required. This also works around dynamic-linking failures with the native
Swift toolchain on the NixOS development machine used for this project:

```sh
make build   # build the package inside the container
make test    # run the test suite inside the container
```

See [AGENTS.md](./AGENTS.md) for the full set of Makefile targets (including
`make shell` and `make docs`) and how the containerized flow is set up.

## Contributing

For agent- and maintainer-facing conventions used in this fork (build/test
commands, workflow, coding conventions, git identity rules), see
[AGENTS.md](./AGENTS.md). For the modernization plan, see
[ROADMAP.md](./ROADMAP.md).

## License

Code and documentation copyright 2019 Siemens AG.

Code is licensed under the [MIT License](https://opensource.org/licenses/MIT).

Documentation is licensed under a [Creative Commons Attribution-ShareAlike 4.0
International License](http://creativecommons.org/licenses/by-sa/4.0/).

The following list displays all the relevant licenses for third-party software
Axoloty depends on:

-   RxSwift [MIT
    License](https://github.com/ReactiveX/RxSwift/blob/master/LICENSE.md)
-   CocoaMQTT [MIT
    License](https://github.com/emqtt/CocoaMQTT/blob/master/LICENSE)
-   swift-log [Apache 2.0
    License](https://github.com/apple/swift-log/blob/main/LICENSE.txt)
-   AnyCodable [MIT
    License](https://github.com/Flight-School/AnyCodable/blob/master/LICENSE.md)
