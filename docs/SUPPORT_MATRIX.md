# Axoloty 0.5.1 support matrix

This matrix records the support level for each capability in the 0.5.1
checkpoint, backed by behavioral test evidence. The 0.6 architecture-alignment
delta is tracked separately in the roadmap and gate issues. Support levels use a
consistent vocabulary:

- **Validated** — implementation with behavioral tests, failure/boundary
  tests where applicable, and cross-implementation fixture or live-wire
  evidence where claimed.
- **Supported** — implementation with at least one behavioral test, but
  lacking cross-implementation evidence or failure/boundary coverage.
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
| Advertise / Deadvertise | Validated | Offline fixtures (CoatyJS and legacy CoatySwift); live both directions; embedded physical evidence (10/10). Failure/boundary: invalid-object-type rejection, malformed-input rejection. |
| Discover / Resolve | Validated | Offline fixtures (CoatyJS, legacy); live both directions; embedded physical evidence. Failure/boundary: correlation matching, bounded outstanding Discover, 5s timeout, wrong-correlation rejection, duplicate rejection. |
| Query / Retrieve | Validated | Offline fixtures (CoatyJS); live both directions with filter coverage. Failure/boundary: negative filter scenarios, unknown-operator rejection, unknown-sorting-order rejection. Legacy CoatySwift direction: Compatibility-unverified. |
| Update / Complete | Validated | Offline fixtures (CoatyJS); live both directions. Failure/boundary: omitted-optional-field decoding. Legacy directions: Compatibility-unverified. |
| Call / Return | Validated | Offline fixtures (CoatyJS); live both directions. Failure/boundary: invalid-operation rejection, omitted-field decoding, error-path preservation, duplicate-reply and late-reply lifecycle scenarios. |
| Channel | Validated | Offline fixtures (CoatyJS); live both directions. Failure/boundary: sensor-filtered channel delivery. |

## IO routing

| Capability | Support level | Evidence |
|---|---|---|
| Associate / IoValue | Partial | Host runtime has offline and live-wire coverage. The embedded profile additionally exposes bounded static source/actor endpoint state, but physical endpoint acceptance remains required before it is promoted to supported. |
| IoState | Host-only | Internal-only event; not exchanged cross-implementation. |
| Rule-based IO routing | Supported | 28 offline test cases (rule creation, condition evaluation, precedence, retry, incremental evaluation). No cross-implementation evidence. |

## SensorThings

| Capability | Support level | Evidence |
|---|---|---|
| SensorThings models | Validated | 15 fixture cases including unknown-field, reordered-key, and unicode decoding. Wire round-trip tests for observation result types. Cross-implementation compatibility reduces to proven Advertise/Channel rows. |
| SensorThings controllers | Supported | Broker-backed integration tests (advertise, channel, filtered observation). No dedicated cross-implementation controller evidence. Full parity with CoatyJS is unproven. |

## Object model and lifecycle

| Capability | Support level | Evidence |
|---|---|---|
| Object lifecycle controller | Supported | Async snapshot API with actor-isolated registry. One broker-backed integration test. No cross-implementation evidence. |
| Dynamic object-type registration | Validated | Concurrent registration test (1000 iterations). Unregistered-type reporting test. |
| Unknown/custom object decoding | Validated | Fuzz tests cover unknown fields, malformed input, and truncated payloads. Borrowed and owned raw JSON boundary tests cover nested values, exact-number lexemes, and bounded-capacity failures. |
| Dynamic controller registration | Supported | Public API implemented (post-bootstrap registration, already-started-manager join). No test exercises the dynamic registration path. |

## Transport and connectivity

| Capability | Support level | Evidence |
|---|---|---|
| MQTT reconnect | Validated | Four live network-failure scenarios (reconnect-resubscribe, broker-restart, clean-session, offline-queueing) via controllable TCP proxy. Defect found and fixed (failed connect never rescheduled auto-reconnect). Embedded broker-restart: 11/11 checks. |
| MQTT last will | Validated | Offline fixtures (CoatyJS last-will, graceful-deadvertise). Live: SIGKILL→broker-issued last-will at QoS 0. Embedded: forced-reset last-will 8/8 checks. Cross-implementation Axoloty↔CoatyJS last-will direction: Compatibility-unverified. |
| TLS | Supported | Platform-conditional implementation (NIOSSL on Linux, NIOTransportServices on Apple). Manual macOS oracle verification only — no automated TLS tests. |
| mDNS discovery | Partial | Apple-only implementation (NetServiceBrowser). Explicitly errors on Linux. Zero test coverage. No broker/router service publication. |
| MQTT QoS configuration | Supported | API preserved from legacy CoatySwift. CoatyJS 2.4.0 hardcodes QoS 0; higher QoS is not cross-implementation tested. |

## Platforms

| Platform | Support level | Evidence |
|---|---|---|
| Linux | Validated | Canonical platform. Containerized CI. Platform-specific tests (observation, embedded toolchain). All standard checks pass. |
| macOS | Supported | Platform-conditional implementation (Network.framework). Manual oracle verification only — no automated macOS CI. Package.swift declares macOS 26.0. |
| iOS | Supported | Declared in Package.swift (iOS 26.0). Inherits macOS Apple-platform code path. Zero dedicated test coverage and no CI. |
| ESP32-C6 Embedded Swift | Validated (embedded scope) | 313 on-device vector tests. Six physical harness scenarios: two-device exchange, host interop, CoatyJS bidirectional, last-will, broker-restart. Zero hot-path allocations. Scope: Advertise/Deadvertise, Discover/Resolve only. |

## Wire compatibility evidence summary

Cross-implementation evidence is recorded in
[docs/wire-compatibility.md](../docs/wire-compatibility.md).
The pinned CoatyJS 2.4.0 reference agent is the source of truth for wire
shape. Live wire captures are generated with `make test-wire-live` and
physical embedded evidence with the `make embedded-*-test` harnesses.

| Direction | Status |
|---|---|
| CoatyJS → Axoloty (all event families) | Validated (offline fixtures + live captures) |
| Axoloty → CoatyJS (all event families) | Validated (offline fixtures + live captures) |
| Legacy CoatySwift → Axoloty | Compatibility-unverified (fixtures captured; live oracle pending) |
| Axoloty → Legacy CoatySwift | Compatibility-unverified (live oracle pending) |
| Axoloty ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
| CoatyJS ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
