# Axoloty 0.5.1 support matrix (G4)

This matrix records the support level for the current G4 implementation,
backed by behavioral test evidence. [`VERSION`](../VERSION) remains `0.5.1`
until the 0.6 release gates finish. G5 owns typed IO endpoint ergonomics and
optional SensorThings products. Support levels use a consistent vocabulary:

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
| Advertise / Deadvertise | Validated | Offline fixtures and live CoatyJS directions; embedded physical evidence (10/10). Failure/boundary: invalid-object-type rejection and malformed-input rejection. |
| Discover / Resolve | Validated | Offline fixtures and live CoatyJS directions; embedded physical evidence. Failure/boundary: correlation matching, bounded outstanding Discover, 5s timeout, wrong-correlation rejection, and duplicate rejection. |
| Query / Retrieve | Validated | Offline fixtures and live CoatyJS directions with filter coverage. Failure/boundary: negative filters, unknown-operator rejection, and unknown-sorting-order rejection. |
| Update / Complete | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: omitted-optional-field decoding. |
| Call / Return | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: invalid-operation rejection, omitted-field decoding, error-path preservation, duplicate-reply, and late-reply lifecycle scenarios. |
| Channel | Validated | Offline fixtures and live CoatyJS directions. Failure/boundary: sensor-filtered channel delivery. |

## IO routing

| Capability | Support level | Evidence |
|---|---|---|
| Associate / IoValue | Partial | G4 shared protocol and binding support are implemented. Typed IO endpoint ergonomics remain a G5 product boundary. |
| IoState | Host-only | Internal diagnostic state; not exchanged cross-implementation. |
| Rule-based IO routing | Planned | G5 owns optional IO-routing policy. |

## SensorThings

| Capability | Support level | Evidence |
|---|---|---|
| SensorThings models | Supported (optional) | `AxolotySensorThings` provides bounded Foundation-free schemas backed by retained portable fixtures. |
| SensorThings workflows | Supported (optional) | Source and observer workflows use standard runtime operations; no controller hierarchy is exposed. |

## Object model and lifecycle

| Capability | Support level | Evidence |
|---|---|---|
| Object lifecycle | Validated | `AxolotyRuntime` owns the single-use lifecycle, bounded ingress, reconnect, cancellation, and diagnostics. G4 lifecycle tests cover startup, failure, reconnect, and shutdown ordering. |
| Object lifecycle controllers | Planned | The inherited controller hierarchy is absent from G4; G5 owns any future product controller. |
| Dynamic object-type registration | Validated | Concurrent registration test (1000 iterations). Unregistered-type reporting test. |
| Unknown/custom object decoding | Validated | Fuzz tests cover unknown fields, malformed input, and truncated payloads. Borrowed and owned raw JSON boundary tests cover nested values, exact-number lexemes, and bounded-capacity failures. |
| Dynamic controller registration | Planned | Process-global controller registration was retired with the G3 manager APIs; G5 owns any future registration contract. |
| Runtime event and responder registration | Supported | Runtime definitions register bounded event streams and responders before startup. Registration belongs to the runtime definition, not a process-global controller manager. |

## Transport and connectivity

| Capability | Support level | Evidence |
|---|---|---|
| MQTT reconnect | Validated | Four live network-failure scenarios (reconnect-resubscribe, broker-restart, clean-session, and offline-queueing) via a controllable TCP proxy. Embedded broker-restart: 11/11 checks. |
| MQTT last will | Validated | Offline fixtures (CoatyJS last-will, graceful-deadvertise). Live: SIGKILL→broker-issued last-will at QoS 0. Embedded: forced-reset last-will 8/8 checks. Cross-implementation Axoloty↔CoatyJS last-will direction: Compatibility-unverified. |
| TLS | Supported | Platform-conditional implementation (NIOSSL on Linux, NIOTransportServices on Apple). Manual macOS oracle verification only — no automated TLS tests. |
| mDNS discovery | Unsupported | The G4 runtime does not publish or discover brokers through mDNS. |
| MQTT QoS configuration | Supported | The G4 MQTT binding uses QoS 0, which matches CoatyJS 2.4.0. Higher QoS is not supported by the current binding. |

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
| Legacy CoatySwift → Axoloty | Compatibility-unverified (historical fixtures only) |
| Axoloty → Legacy CoatySwift | Compatibility-unverified (not tested) |
| Axoloty ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
| CoatyJS ↔ ESP32-C6 (Advertise/Deadvertise, Discover/Resolve) | Validated (physical evidence) |
