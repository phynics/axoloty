# Wire compatibility matrix

Reference versions must be pinned before captured fixtures become normative:

- Modern Swift: current `main`
- Legacy Swift: `coatyio/coaty-swift` tag `2.4.0` at `20a97b29832758fb771ac79fd5f7ae36cff69403`
- CoatyJS: `@coaty/core@2.4.0` from tag `v2.4.0` at `4a7716815f9f775db812e7a079146e56e08570d1`
- Broker: Mosquitto from the repository's pinned Linux test image

| Capability | JS → modern | Modern → JS | Legacy → modern | Modern → legacy | Gate |
|---|---|---|---|---|---|
| Advertise | Compatible | Compatible with normalization | Compatible | Not tested (macOS runner consumer mode added, requires macOS host) | PR |
| Deadvertise | Compatible | Compatible with normalization | Compatible | Not tested (macOS runner consumer mode added, requires macOS host) | PR |
| Discover / Resolve | Compatible | Compatible with normalization | Compatible | Not tested (macOS runner responder mode added, requires macOS host) | PR |
| Query / Retrieve | Compatible | Compatible with normalization (filters exercised) | Not tested | Not tested (macOS runner responder mode added, requires macOS host) | PR |
| Update / Complete | Compatible | Compatible with normalization | Not tested | Not tested (macOS runner consumer mode pending) | PR |
| Call / Return | Compatible | Compatible with normalization | Not tested | Not tested (macOS runner responder mode added, requires macOS host) | PR |
| Channel | Compatible | Compatible with normalization | Not tested | Not tested (macOS runner consumer mode added, requires macOS host) | PR |
| Identity lifecycle / last will | Not tested | Not tested | Not tested | Not tested | Nightly |
| Associate / IoState / IoValue | Partial | Partial | Not tested | Not tested | Nightly |
| Decentralized logging | Not tested | Not tested | Not tested | Not tested | Nightly |
| SensorThings | Fixture-backed | Fixture-backed | Not tested | Not tested | G5 |
| Payloads above 2,048 bytes | Intentional divergence: rejected by Axoloty | Intentional divergence: Axoloty does not emit | Intentional divergence: rejected by Axoloty | Intentional divergence: Axoloty does not emit | Boundary fixtures and ESP32 vectors |

### G5 host typed IO evidence

Host typed IO uses the same bounded `ProtocolProcessor` path as static IO for
endpoint Advertise, Deadvertise, and IoValue publications. The host regression
suite covers endpoint normalization and catalogue-capacity rollback; the
required live CoatyJS capture/verifier remains the merge gate for the new
transport path. This slice intentionally adds the optional externalRoute
field to a source Advertise when a validated external MQTT route is configured;
route-less sources retain the prior field omission. The field-presence change is
covered by the host Advertise regression and is not used by static registration.

### G4 embedded Advertise topic normalization

The shared static-runtime migration corrected the embedded Advertise topic
builder so the object-type filter is emitted as `ADV:coaty.test.Device`
(not the legacy `ADV::coaty.test.Device` form). The exact ESP32-C6 smoke
vector in `Embedded/swift/main/StaticDeviceAgent.swift` locks this output;
the correction is intentional and keeps the topic aligned with the pinned
Coaty Core 3 grammar.

### Host lifecycle publications through the shared processor

Host startup, reconnect, and graceful shutdown now construct Identity
Advertise and Deadvertise operations at the runtime boundary and route them
through `ProtocolProcessor.processOutbound`. The MQTT binding only selects the
normalized topic and publishes the owned action. This preserves the canonical
Coaty/3 Deadvertise envelope (`{"objectIds":["..."]}`) and keeps lifecycle
state updates on the same bounded processor path as application publications.

### G2 external-route semantics

The binding-owned external-route fixture is exactly
`external/wire-compat-v1/io-external-1`. The positive CoatyJS Associate payload
does **not** serialize `isExternalRoute`; its classification is supplied as
trace/binding metadata. G2 offline coverage records all of the following as
shared-processor evidence:

- omitted `isExternalRoute` is accepted;
- an explicit value is accepted only when it agrees with the binding
  classifier;
- a contradictory value is rejected without state mutation; and
- an unrelated route is ignored.

The fixed-inline processor and both host/static trace adapters have unit
coverage for these semantics. Live cross-implementation IO evidence remains
governed by the existing IO runners and is a separate transport/runtime gate.

Allowed results are `Compatible`, `Compatible with normalization`, `Intentional divergence`, `Unsupported`, and `Not tested`. Any intentional divergence requires a linked decision and fixture update.

### Decision: Axoloty 2 KiB payload ceiling

Coaty and the pinned CoatyJS reference implementation do not define Axoloty's
2,048-byte event-payload limit. Axoloty deliberately adds this limit across its
host and embedded profiles to keep parser, protocol-state, retained-action, and
transport storage finite and measurable on ESP32-class devices. It is an
Axoloty platform constraint, not part of the Coaty Core 3 wire grammar.

Axoloty accepts payloads of at most 2,048 bytes. Axoloty rejects larger inbound
payloads before parsing or protocol-state mutation. It rejects larger outbound
payloads before publication. Axoloty does not fragment or reassemble oversized
Coaty messages. A Coaty peer that relies on payloads above 2 KiB is not
wire-compatible with Axoloty for those messages.

This decision is locked by the exact-limit and one-over-limit fixtures in
[WireBoundsTests.swift](../Packages/AxolotyWire/Tests/AxolotyWireTests/WireBoundsTests.swift),
the shared protocol action-sink tests, and the physical ESP32 vectors in
[Main.swift](../Embedded/swift/main/Main.swift). Static runtimes may choose a
smaller compile-time capacity, which narrows compatibility further for that
firmware.

As of issue #397, both shipping host directions use AxolotyWire event codecs:
ingress owns `BorrowedWireEvent` before async delivery, and publication uses
`OwnedWireEvent.encode(to:)`. Host-only registration, core fallback, unknown
types, and custom-field hydration remain in Axoloty and do not extend the
AxolotyWire dependency boundary. This is an ownership change only; it adds no
intentional wire divergence and preserves the Call/Return shapes above.

`Modern → JS` for the seven core capabilities is backed by `Tests/Support/WireCompatibility/Reverse/`: Axoloty produces (or, for request/reply pairs, requests) against the pinned CoatyJS 2.4.0 reference agent. For the five request/reply pairs (Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return) the assertion lives in the Swift test itself, decoding CoatyJS's response and checking its fields with `#expect`. For the two one-way events (Deadvertise, Channel), `AxolotyCoreProducerTests.swift` only publishes; the decoded-semantics check instead happens in `run-axoloty-core.sh`, which greps the CoatyJS consumer process's log for its `"state":"ack"` line, itself only emitted after the consumer's own field-level match succeeds. Either way, delivery alone is never treated as sufficient. It is marked "with normalization" because dynamic identifiers and timestamps are normalized before comparison.

Query/Retrieve additionally exercises `objectFilter` (#119): the `query-retrieve` scenario publishes an `Equals` filter on `name` that matches the fixture, and pinned CoatyJS 2.4.0 evaluates it via `event.data.matchesObject`. A negative filter (`query-retrieve-filter-negative`) asserts no Retrieve arrives. Operand-type coverage (`query-retrieve-filter-operands`) tests int, double, bool, and null operands — all non-matching, proving the reference implementation parses these types without error. Number-typing preservation (e.g. `42` staying `Int`, not `42.0`) is **not** covered by this scenario: JavaScript numbers are all doubles, so CoatyJS's `matchesObject` happily matches `42.0` against `42`. That gap is covered separately by #112's characterization tests.

> **Known CoatyJS 2.4.0 defect:** `QueryEventData.matchesObject` in `@coaty/core@2.4.0` uses `||` instead of `&&` between type matching and filter matching (`object-matcher.js:matchesFilter`). When `_coreTypes` is undefined (the common case where only `objectTypes` is set), the first clause short-circuits to `true` and the `objectFilter` is never evaluated. The `query-retrieve-filter-negative` and `query-retrieve-filter-operands` scenarios bypass `matchesObject` and call `ObjectMatcher.matchesFilter` directly, so the filter is actually checked. The positive `query-retrieve` scenario still uses `matchesObject` because it only asserts a match (which the bug does not affect).

`JS → modern` is backed by live cross-implementation scenarios in `Tests/Support/WireCompatibility/Reverse/`: `run-coatyjs-to-axoloty-advertise.sh` covers Advertise and `run-coatyjs-to-axoloty-core.sh` covers Deadvertise, Channel, Discover/Resolve, Query/Retrieve, Update/Complete, and Call/Return. Each starts pinned CoatyJS 2.4.0 and Axoloty in an isolated broker network, gates publication on a file written after Axoloty acquires its MQTT subscription, and asserts decoded semantic fields in Swift Testing. For request/response capabilities, Axoloty validates the request and publishes the correlated response while the CoatyJS requester validates the response. These scenarios were run end-to-end with Podman on Linux; no Python capture or verification script is involved.

Identity lifecycle / last will has nine executable live scenarios of eleven, evidenced by `Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh`. Three (`unexpected-disconnect-last-will`, `qos-0`, `graceful-deadvertise`) have both subject and observer as CoatyJS reference agents, so they are not cross-implementation evidence for either directional column. Six have **Axoloty as the genuine live subject**: `duplicate-reply` and `late-reply` (Axoloty as Call/Return initiator against pinned CoatyJS 2.4.0 as a deliberately misbehaving responder, via `run-lifecycle-call-return.sh`), and the four network-failure scenarios `offline-queueing`, `reconnect-resubscribe`, `broker-restart`, and `clean-session` (via `run-lifecycle-network.sh`, which severs and restores the subject's broker connectivity through a controllable TCP proxy — or really stops and restarts Mosquitto — and proves post-reconnect re-subscription by having Axoloty decode an Advertise probe published by pinned CoatyJS 2.4.0 only after the reconnect; `clean-session` additionally verifies proxy-decoded CONNACK `sessionPresent=false` handshakes). All were verified end-to-end via containerized runners, cross-referencing an independent MQTT capture against the timestamped Axoloty application log, not merely a process exit code. Getting `broker-restart` to pass exposed and fixed a real defect: `MQTTNIOClient`'s failed connect attempts never rescheduled auto-reconnect (only established-then-closed connections fire mqtt-nio's close listener), so one refused attempt against a not-yet-listening broker permanently ended reconnection. See `Tests/Support/WireCompatibility/Lifecycle/Live/README.md` for the full disposition of every catalog scenario. `qos-1`/`qos-2` remain `unsupported` for a separate, verified reason: pinned `@coaty/core@2.4.0` hardcodes QoS 0 for every publish regardless of configuration. Legacy CoatySwift 2.4.0 is descoped as a live lifecycle subject by recorded decision: see `Tests/Support/WireCompatibility/Audit/LegacySwiftLifecycleScopeDecision.md`.

`Legacy → modern` for Advertise, Deadvertise, and Discover/Resolve is backed by real, provenance-bound CoatySwift 2.4.0 captures generated on a macOS host (`Tests/AxolotyTests/WireCompatibility/Fixtures/coatyswift-2.4.0/*.jsonl` plus their `*.manifest.json`) and decoded by `WireCaptureContractTests.swift`, which asserts the decoded Swift event's semantic fields, not only that the capture parses. Generating these captures required two fixes to the previously unexercised macOS runner (`Tests/Support/WireCompatibility/Legacy/macOS-runner/`), documented in that directory's README: pinned CoatySwift 2.4.0's CocoaMQTT client dispatches socket callbacks on the main queue, so the runner's blocking `Thread.sleep`/`DispatchSemaphore.wait` calls starved that queue and silently dropped every publication; and the Discover/Resolve requester and responder identities produced an identical truncated MQTT ClientID, so the broker repeatedly disconnected one side. `Modern → legacy` (Axoloty producing for a legacy CoatySwift consumer) is not implemented and remains `Not tested`; the macOS runner in this repository is a producer-only scenario driver, not a consumer.

Reference-agent pins, build instructions, and the documented legacy Swift
platform constraint live in `Tests/Support/WireCompatibility/ReferenceAgents/README.md`.

The ESP32-C6 embedded-to-embedded Phase 4 slice uses production AxolotyWire,
fixed-capacity topic and payload buffers, and the ESP-IDF MQTT client against a
real broker. The static device agent validates checksummed serial evidence for
Advertise, correlated Discover/Resolve, graceful Deadvertise, and disconnect,
plus the failure-mode contract added in #325: a single bounded outstanding
Discover request, a deterministic 5-second Resolve timeout polled by the C
wait loop, wrong-correlation Resolve rejection, and duplicate-Resolve
rejection. Byte-exact device vectors lock the generated Advertise, Deadvertise,
Discover, and Resolve topics and payloads against the
`coaty/<version>/<namespace>/<eventType>:<filter>/<sourceId>[/<correlationId>]`
contract. Physical evidence was captured under #326 and is recorded under
`.testing/embedded/`; it does not change the JS/modern columns above, which
require separate pinned CoatyJS directions.

**Captured physical evidence (#326):**

- `make embedded-agent-test` — two ESP32-C6 devices (A↔B): 10/10 exchange
  checks passed on both devices (WiFi, IP, MQTT connect, subscribe, reconnect,
  Advertise, Discover, Resolve, Deadvertise, disconnect). Zero hot-path
  allocations. Artifacts: `agent-a-result.json`, `agent-b-result.json`.
- `make embedded-swift-test` — on-device vector corpus: 313/313 tests passed
  including the #325 lifecycle vectors (bounded Discover, timeout, duplicate
  rejection, callback-boundary state, byte-exact topic/payload fixtures). Zero
  hot-path allocations. Artifacts: `vector-swift-smoke-result.json`.
- `make embedded-host-test` — host Axoloty ↔ ESP32-C6 (role A): Swift
  `EmbeddedHostInteroperabilityTests` passed (host discovers embedded Advertise,
  publishes Discover, receives Resolve, observes Deadvertise). Device serial:
  10/10 exchange checks passed. Artifacts: `embedded-host-a-result.json`.
- `make embedded-coatyjs-test` (role A) — pinned `@coaty/core@2.4.0` requester
  → embedded responder: CoatyJS published Discover, received Resolve with
  correct correlation ID and object ID. Device: 10/10 checks passed.
  Artifacts: `coatyjs-a-result.json`.
- `make embedded-coatyjs-test` (role B) — embedded requester → pinned
  `@coaty/core@2.4.0` responder: CoatyJS published Resolve and Deadvertise in
  response to the embedded Discover. Device: 10/10 checks passed.
  Artifacts: `coatyjs-b-result.json`.
- `make embedded-last-will-test` — forced-reset last-will: observer saw
  device Advertise, then broker-issued Deadvertise after forced reset. Device:
  8/8 exchange checks passed (no Discover/Resolve in this scenario).
  Artifacts: `embedded-last-will-result.json`, `embedded-last-will-observer.jsonl`.
- `make check-budget-manifest` — budget manifest validation passed.
- `make embedded-broker-restart-test` — managed broker restart/reconnect:
  device connected, broker was killed and restarted, device reconnected and
  received Advertise/Resolve/Deadvertise from the responder. 11/11 exchange
  checks passed (including `exchange:brokerReconnect`). Zero hot-path
  allocations. Artifacts: `embedded-broker-restart-result.json`,
  `embedded-broker-restart-serial.log`.

The Phase 4 embedded↔CoatyJS harness is implemented by
`make embedded-coatyjs-test`. It runs one pinned `@coaty/core@2.4.0` runner
per physical direction: CoatyJS requests the fixed embedded A exchange, or
CoatyJS advertises/responds to embedded B. The matching host Axoloty harness
is `make embedded-host-test`, with role A covering host Discover → embedded
Resolve and role B covering host Advertise → embedded Discover → host Resolve
→ host Deadvertise. `make embedded-last-will-test` distinguishes a
broker-issued Deadvertise after a forced device reset from the graceful path,
while `make embedded-broker-restart-test` requires a received message after
automatic reconnect and wildcard resubscription. All harnesses passed with
reviewed physical evidence under `.testing/embedded/`.

`Associate / IoState / IoValue` is backed by `Tests/AxolotyLiveWireTests/IO/`
(T-021). Generic Associate and IoValue wire families remain owned by
`AxolotyProtocol` and `AxolotyWire`; the current live subjects use
`AxolotyRuntime` and bounded peer acknowledgements. The matrix stays `Partial`
until the forced live gate is rerun in CI. The G4 runtime does not ship
controller-based or rule-based IO routing, and `IoState` is an internal API,
not a wire publication. Legacy CoatySwift IO directions remain descoped by
`Audit/LegacySwiftIOScopeDecision.md` (no macOS/Xcode host). JS integer
IoValues exceeding 2^53 lose precision through CoatyJS's float64
(`Int64.max` round-trips as `9223372036854776000`); Axoloty preserves Int64
exactly.

`SensorThings` is an optional G5 product. Its bounded schema models and source/
observer workflows are covered by retained portable fixtures and the already-
proven standard Coaty Advertise, Discover/Resolve, Query/Retrieve, and Channel
event paths. No compatible CoatyJS SensorThings package is available, so this
row intentionally records fixture evidence rather than fabricating live
SensorThings interoperability claims.

## CI enforcement of live wire evidence

Protocol-affecting changes must record live CoatyJS wire compatibility evidence
or carry a reviewed exemption before merge, enforced by the repository's
required `Live CoatyJS compatibility gate` check (issue #457).

**Protocol-affecting paths** (authoritative list in
`Tests/Support/classify-wire-change.mjs`, `PROTOCOL_AFFECTING`):

- `Packages/AxolotyWire/**` — AxolotyWire codec, routing, and package-owned tests.
- `Source/**` — host wire codecs, events, core types, IO routing, SensorThings.
- `Tests/AxolotyTests/WireCompatibility/**` — offline Swift wire tests and committed fixtures.
- `Tests/AxolotyLiveWireTests/**` — live Swift subjects, compiled separately and gated by the live environment.
- `Tests/Support/WireCompatibility/**` — live scenarios, reference agents,
  capture/verifier tooling, and other wire test infrastructure (Markdown,
  decision records, and the `Audit/` tree stay on the fast path).
- `Package.swift` and `Package.resolved` — package manifest and resolved
  dependency graph.

The `Source/Axoloty.docc/**` documentation tree, and changes to test
orchestration (`Makefile`, `Tests/Support/test-tiers.json`, `Tools/`,
`.github/`), do not change the bytes that flow across a wire and stay on the
fast path.

**Gate behavior.** The `Live CoatyJS compatibility gate` job always runs (it is
a reliable required status check). When a change set contains a
protocol-affecting path, the gate runs the containerized live CoatyJS capture
and its verifier (`make test-wire-live`) and requires the resulting captures and
manifest. When no protocol-affecting path changed, the gate fast-paths to a
pass without the expensive capture.

**Exemption mechanism.** Add the `live-wire-exemption` label to a
protocol-affecting PR together with a recorded rationale and expiry in the PR
description (typically an issue or decision reference). The label waives only
the live capture; it is never treated as a protocol-affecting pass, so the
`protocol=/exempt=` disposition is recorded in the workflow summary. Exemptions
are visible, dated, and expire with their linked decision. Example exemption,
used only when matching the reference agent is impossible or more harmful than
breaking compatibility (see AGENTS.md "Wire compatibility"):
`live-wire-exemption` + PR description citing the recorded decision and expiry.
