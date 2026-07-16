# Coaty feature matrix

This matrix compares three distinct products rather than assuming historical
feature parity:

- **CoatyJS 2.4.x** — the broad reference implementation and ecosystem.
- **CoatySwift 2.4.0** — the final upstream Swift release used as the legacy
  Swift compatibility oracle.
- **Axoloty** — this repository's current `master`, newly renamed at the
  package level while its library product and Swift module are still named
  `CoatySwift`.

Legend: **Yes** = implemented; **Partial** = useful subset or platform-limited;
**No** = not implemented; **Planned** = tracked but not implemented. “Present”
does not mean cross-language compatibility has already been proven; see the
wire-evidence section and `../Tests/WireCompatibility/CompatibilityMatrix.md`.

## Runtime and platform

| Feature | CoatyJS 2.4.x | CoatySwift 2.4.0 | Axoloty | Notes |
|---|---|---|---|---|
| IoC container, controllers, runtime/configuration | Yes | Yes | Yes | Shared Coaty component model; APIs are language-specific. |
| Declarative controller registration | Yes | Yes | Yes | Core capability in all three. |
| Dynamic controller registration | Yes | Yes | Yes | Lifecycle details still need differential tests. |
| Controllerless containers | Yes | Yes | Yes | Swift accepts an empty controller registry while retaining its fixed communication/runtime graph. |
| Node.js runtime | Yes | No | No | JS includes Node-specific runtime utilities. |
| Browser runtime | Yes | No | No | JS targets browser applications and bundlers. |
| Angular/Ionic integration | Yes | No | No | JS provides a specialized Angular runtime module. |
| Apple platforms | Via browser/hybrid | Yes | Yes | Legacy Swift targets iOS/iPadOS/macOS. |
| Linux-native runtime | Yes | No | Yes | Axoloty builds and tests in a Swift Linux container. |
| WebAssembly runtime | Via browser JS | No | Planned | Native SwiftWasm exploration remains a roadmap item. |
| Swift Package Manager | N/A | Yes | Yes | Axoloty is SPM-only. |
| CocoaPods distribution | N/A | Yes | No | Intentionally removed by Axoloty. |

## Object model

| Feature | CoatyJS 2.4.x | CoatySwift 2.4.0 | Axoloty | Notes |
|---|---|---|---|---|
| Coaty core object hierarchy | Yes | Yes | Yes | CoatyObject, Identity, User, Task, Log, IO types, etc. |
| Application-specific object types | Yes | Yes | Yes | Type registration exists in both Swift lines. |
| Unknown/custom property decoding | Yes | Yes | Yes | Axoloty retains Swift's `custom` property behavior. |
| Runtime schema validation | Yes | No | No | JS validates core object shapes; Swift relies primarily on `Codable` decoding. |
| Object filters and sorting | Yes | Yes | Yes | Query semantics need fixture and live verification. |
| UUID v4/lowercase wire representation | Yes | Yes | Yes | Covered by the shared Coaty wire contract. |
| Semantic golden-fixture regression tests | Extensive integration suite | No dedicated cross-version suite | Partial | Axoloty now has resource-backed fixtures; reference coverage is being expanded. |

## Communication and transport

| Feature | CoatyJS 2.4.x | CoatySwift 2.4.0 | Axoloty | Notes |
|---|---|---|---|---|
| Advertise / Deadvertise | Yes | Yes | Yes | Axoloty has a verified live CoatyJS→wire Advertise slice. |
| Discover / Resolve | Yes | Yes | Yes | API present; new differential matrix pending. |
| Query / Retrieve | Yes | Yes | Yes | API present; new differential matrix pending. |
| Update / Complete | Yes | Yes | Yes | API present; new differential matrix pending. |
| Call / Return | Yes | Yes | Yes | API present; new differential matrix pending. |
| Channel | Yes | Yes | Yes | Current Swift integration tests cover Swift↔Swift behavior. |
| Raw string/binary topics | Yes | Yes | Yes | Exact cross-language binary behavior is not yet fully captured. |
| Deferred offline publication/subscription | Yes | Yes | Yes | Axoloty has scenario contracts; live failure execution remains pending. |
| Distributed lifecycle / MQTT last will | Yes | Yes | Yes | Live cross-version lifecycle evidence remains pending. |
| MQTT transport | Yes | Yes | Yes | JS uses MQTT.js; legacy Swift used CocoaMQTT; Axoloty uses mqtt-nio. |
| WAMP transport | Yes | No | No | JS documents MQTT and WAMP bindings; Swift implements MQTT only. |
| TLS MQTT | Yes | Yes | Yes | Axoloty uses Network.framework on Apple platforms and NIOSSL on Linux. |
| MQTT QoS configuration | Yes | Yes | Yes | Axoloty preserves the old Swift API, including known raw-byte publish quirks. |
| Broker discovery via mDNS | Yes | Partial | Partial | JS can publish/discover services; Swift discovery is Apple-only, and Axoloty explicitly errors on unsupported platforms. |
| Broker/router service publication via mDNS | Yes | No | No | Node-specific JS utility; Swift only has discovery support. |

## Higher-level framework modules

| Feature | CoatyJS 2.4.x | CoatySwift 2.4.0 | Axoloty | Notes |
|---|---|---|---|---|
| IO routing core model/events | Yes | Yes | Yes | Associate, IoValue, IoState, router/source/actor controllers exist in Swift. |
| Rule-based/context-driven IO routing | Yes | Yes | Yes | Cross-language routes and backpressure behavior are not yet proven. |
| IO backpressure strategies | Yes | Yes | Yes | Raw-value behavior is an open Axoloty audit item. |
| Unified Storage API | Yes | No | No | Swift has database configuration value types, not JS's storage API. |
| In-memory database adapter | Yes | No | No | JS specialized module. |
| PostgreSQL adapter | Yes | No | No | JS/Node specialized module. |
| SQLite Node/Cordova adapters | Yes | No | No | JS platform-specific modules. |
| SensorThings object model | Yes | Yes | Yes | Swift includes Sensor, Thing, Observation, and FeatureOfInterest. |
| SensorThings controllers/workflows | Yes | Yes | Yes | Swift has source/observer controllers; full parity with JS is unproven. |
| Sensor hardware IO helpers | Yes | Partial | Partial | Both expose SensorThings IO concepts, but JS has broader platform-specific modules. |
| Object lifecycle controller | Yes | Yes | Yes | Swift implementation and tests exist. |
| Decentralized structured logging | Yes | Yes | Yes | Axoloty migrated its local logging backend to swift-log. |
| Rights-management guidance/framework integration | Yes/Documented | No dedicated module | No dedicated module | Do not infer security parity from event compatibility. |

## Developer ecosystem and operations

| Feature | CoatyJS 2.4.x | CoatySwift 2.4.0 | Axoloty | Notes |
|---|---|---|---|---|
| Reactive API | RxJS | RxSwift 5 | None | Axoloty uses structured-concurrency EventHub streams; RxSwift is removed. |
| Standard logging facade | JS console/framework utilities | XCGLogger | swift-log | Wire `Log` objects remain separate from local log backends. |
| Project template / generator | Yes | No | No | JS ships a Node/TypeScript agent template and project scripts. |
| Build metadata generation/release scripts | Yes | No equivalent | Partial | Axoloty has container/Make workflows but not JS's agent-project toolchain. |
| Complete maintained developer guide/API site | Yes | Legacy Jazzy/Jekyll docs | No | Axoloty removed generated legacy docs; DocC replacement is planned. |
| Linux CI | Yes | No | Yes | Axoloty runs containerized Swift build/tests. |
| Cross-implementation wire suite | JS integration tests/examples | Informal interoperability/examples | Partial | Axoloty now pins references, captures MQTT, and gates offline fixtures. |

## Current wire-compatibility evidence

| Direction/capability | Status |
|---|---|
| CoatyJS 2.4.0 → Axoloty Advertise | **Verified** for deterministic object payload, both core/object-type topics, QoS 0, and retain=false. |
| Axoloty → CoatyJS | Not yet verified live. |
| Legacy CoatySwift 2.4.0 → Axoloty | Reference pin exists; captured fixtures and macOS oracle runner pending. |
| Axoloty → legacy CoatySwift 2.4.0 | Pending macOS oracle runner. |
| Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return | APIs exist in all implementations; four-direction differential evidence pending. |
| IO routing and SensorThings | Source-backed audit complete; reference captures and keep/diverge/remove decisions pending. |
| Reconnect, broker restart, clean session, last will, QoS | Machine-checkable scenario catalog exists; live cross-version execution pending. |

## Interpretation

Axoloty's current advantage over legacy CoatySwift is portability and
maintainability: Linux support, mqtt-nio, swift-log, structured concurrency, container
testing, and an emerging compatibility harness. It should not be described as
feature-equivalent to CoatyJS. Closing selected gaps should be driven by the
wire matrix and actual Axoloty use cases, not by an assumption that every JS
platform module belongs in Swift.

## Evidence sources

- [CoatyJS developer guide](https://coatyio.github.io/coaty-js/man/developer-guide/)
- [Coaty communication-event specification](https://coatyio.github.io/coaty-js/man/communication-events/)
- [Legacy CoatySwift developer guide](https://coatyio.github.io/coaty-swift/man/developer-guide/)
- Axoloty source tree under `../Source/`, roadmap, container tests, and
  `../Tests/WireCompatibility/`
