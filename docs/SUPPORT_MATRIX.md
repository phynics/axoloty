# Axoloty 0.9.0 support matrix

This matrix records the support level for the current implementation, backed
by behavioral test evidence. [`VERSION`](../VERSION) is `0.9.0`. Typed IO
endpoint ergonomics and the optional SensorThings products are part of the
product surface. Support levels use a consistent vocabulary:

- **Validated** — implementation with behavioral tests, failure/boundary
  tests where applicable, and cross-implementation fixture or live-wire
  evidence where claimed.
- **Supported** — implementation with at least one behavioral test, but
  lacking cross-implementation evidence or failure/boundary coverage.
- **Best effort** means a declared platform without dedicated CI. Manual
  evidence covers only the configurations and scenarios recorded.
- **Partial** — useful subset or platform-limited; evidence is incomplete.
- **Experimental** — implemented but not tested at production quality.
- **Compatibility-unverified** — implementation exists but
  cross-implementation interoperability has not been tested.
- **Host-only** — available in the host runtime, not on embedded targets.
- **Embedded-only** — available on embedded targets, not in the host runtime.
- **Unsupported** — not implemented.
- **Planned** — tracked but not implemented.

## Communication events

| Capability | Support level | Evidence |
|---|---|---|
| Advertise / Deadvertise | Validated | Offline fixtures and live CoatyJS directions; embedded physical evidence (10/10). Failure/boundary: invalid-object-type rejection and malformed-input rejection. |
| Discover / Resolve | Validated | Offline fixtures and live CoatyJS directions; embedded physical evidence. Failure/boundary: correlation matching, bounded outstanding Discover, 5s timeout, wrong-correlation rejection, and duplicate rejection. |
| Query / Retrieve | Validated | Offline fixtures and live CoatyJS directions with filter coverage. Failure/boundary: negative filters, unknown-operator rejection, and unknown-sorting-order rejection. |
| Update / Complete | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: omitted-optional-field decoding. |
| Call / Return | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: invalid-operation rejection, omitted-field decoding, error-path preservation, duplicate-reply, and late-reply lifecycle scenarios. |
| Channel | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: sensor-filtered channel delivery. |

## IO routing

| Capability | Support level | Evidence |
|---|---|---|
| Associate / IoValue | Supported (optional) | Shared protocol and binding support are implemented; typed endpoint and routing behavior is covered by `AxolotyIoRouting` and runtime tests. Cross-implementation evidence remains incomplete. |
| IoState | Host-only | Internal diagnostic state; not exchanged cross-implementation. |
| Rule-based IO routing | Supported (optional) | `AxolotyIoRouting` provides bounded host-side Basic IO routing with atomic registration and scoped endpoint matching. |

## SensorThings

| Capability | Support level | Evidence |
|---|---|---|
| SensorThings models | Supported (optional) | `AxolotySensorThingsModel` provides bounded Foundation-free schemas and JSON codecs backed by retained portable fixtures. |
| SensorThings workflows | Supported (optional) | One atomic module provides source, fixed-Sensor observation, and separate bounded Thing-driven Sensor-registry workflows over standard runtime operations; no controller hierarchy is exposed. |

## Object model and lifecycle

| Capability | Support level | Evidence |
|---|---|---|
| Object lifecycle | Validated | `AxolotyRuntime` owns the single-use lifecycle, bounded ingress, reconnect, cancellation, and diagnostics. G4 lifecycle tests cover startup, failure, reconnect, and shutdown ordering. |
| Object lifecycle controllers | Unsupported | The inherited controller hierarchy is not part of the current runtime; use explicit runtime modules and handlers. |
| Dynamic object-type registration | Validated | Concurrent registration test (1000 iterations). Unregistered-type reporting test. |
| Unknown/custom object decoding | Validated | Wire parser bounds tests cover unknown fields, malformed input, and truncated payloads. Borrowed and owned raw JSON boundary tests cover nested values, exact-number lexemes, and bounded-capacity failures. |
| Dynamic controller registration | Unsupported | Process-global controller registration was retired with the manager APIs and has no current replacement contract. |
| Runtime event and responder registration | Supported | Runtime definitions register bounded event streams and responders before startup. Registration belongs to the runtime definition, not a process-global controller manager. |

## Transport and connectivity

| Capability | Support level | Evidence |
|---|---|---|
| MQTT reconnect | Validated | Four live network-failure scenarios (reconnect-resubscribe, broker-restart, clean-session, and offline-queueing) via a controllable TCP proxy. Embedded broker-restart: 11/11 checks. |
| MQTT last will | Supported | Host binding installs the identity deadvertisement as a non-retained QoS 0 will; focused adapter/runtime tests cover its route and payload. Live host SIGKILL evidence is pending. Embedded: forced-reset last-will 8/8 checks. Cross-implementation Axoloty↔CoatyJS last-will direction: Compatibility-unverified. |
| TLS | Supported | Platform-conditional implementation (NIOSSL on Linux, NIOTransportServices on Apple). Manual macOS oracle verification only — no automated TLS tests. |
| mDNS discovery | Unsupported | The G4 runtime does not publish or discover brokers through mDNS. |
| MQTT QoS configuration | Supported | The G4 MQTT binding uses QoS 0, which matches CoatyJS 2.4.0. Higher QoS is not supported by the current binding. |
| Zenoh transport, host client mode | Experimental | `AxolotyZenoh` package over pinned `zenoh-c` 1.10.0. Evidence: the offline façade-contract and conformance tier (`zenoh-offline`) and the live pinned-`zenohd` tier (`zenoh-live`), both in Linux CI and runnable natively on macOS arm64, plus MQTT↔Zenoh protocol-trace parity tests. Experimental because the package is consumable only from a checkout (path dependency, ADR 0007) and its wire encoding moves to `axoloty/1` CBOR, the only Zenoh encoding from 1.0 ([ADR 0009](./adr/0009-zenoh-carries-only-axoloty-1.md)), so 0.9 Zenoh peers will not interoperate with 1.0 Zenoh peers. See [docs/transports/zenoh.md](./transports/zenoh.md). |
| Zenoh transport, host peer mode | Experimental | Routerless scenario in the `zenoh-live` tier. Same limits as client mode. Router loss is not reported in peer mode. |
| Zenoh Embedded-Swift core (`AxolotyZenohCore`) | Experimental | Compiled and partially linked for RISC-V by the hardware-free `zenoh-core-embedded` pull-request node, which needs no zenoh-c archive, router, or device. No firmware session or device evidence exists in this repository. |
| Zenoh transport, ESP32-C6 | Planned | Firmware builds reproducibly in `phynics/axoloty-embedded`; device qualification is pending ([axoloty-embedded#8](https://github.com/phynics/axoloty-embedded/issues/8)). |

## Platforms

| Platform | Support level | Evidence |
|---|---|---|
| Linux | Validated | Canonical platform. The [CI workflow](../.github/workflows/ci.yml) runs the required checks in the pinned Linux container, including host tests and the hardware-free Embedded Swift gate. |
| macOS | Best effort | `Package.swift` declares macOS 26.0; the Apple MQTT path uses Network.framework. No automated macOS CI. Verification is manual: use the [macOS oracle procedure](./testing.md#manual-macos-oracle). Recorded [macOS arm64 Zenoh tier results](./dependencies/zenoh.md#host-macos-266-arm64-xcode-27-swift-64-native) cover that transport and configuration. |
| iOS | Best effort | `Package.swift` declares iOS 26.0 and selects the Apple MQTT implementation. No dedicated iOS device/simulator tests or CI. Shared Apple code and macOS results do not establish iOS validation. |
| ESP32-C6 Embedded Swift | Validated at 0.8 (embedded scope) | 313 on-device vector tests. Six physical harness scenarios: two-device exchange, host interop, CoatyJS bidirectional, last-will, broker-restart. Zero hot-path allocations. Scope: Advertise/Deadvertise, Discover/Resolve only. Device qualification now lives in `phynics/axoloty-embedded`. No profile holds an unrevoked certificate at the current Core revision, and requalification is tracked in [#796](https://github.com/phynics/axoloty/issues/796). |

## Wire compatibility evidence summary

Cross-implementation evidence is recorded in
[docs/wire-compatibility.md](../docs/wire-compatibility.md).
The pinned CoatyJS 2.4.0 reference agent is the source of truth for wire
shape. Live wire captures are generated with `make test-tier TIER=wire` and
physical embedded evidence with the `make embedded-*-test` harnesses.

| Direction | Status |
|---|---|
| CoatyJS → Axoloty (all event families) | Validated (offline fixtures + live captures) |
| Axoloty → CoatyJS (all event families) | Validated (offline fixtures + live captures) |
| Legacy CoatySwift → Axoloty | Compatibility-unverified (historical fixtures only) |
| Axoloty → Legacy CoatySwift | Compatibility-unverified (not tested) |
| Axoloty ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
| CoatyJS ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
