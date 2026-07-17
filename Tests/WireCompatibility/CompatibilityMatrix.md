# Wire compatibility matrix

Reference versions must be pinned before captured fixtures become normative:

- Modern Swift: current `main`
- Legacy Swift: `coatyio/coaty-swift` tag `2.4.0` at `20a97b29832758fb771ac79fd5f7ae36cff69403`
- CoatyJS: `@coaty/core@2.4.0` from tag `v2.4.0` at `4a7716815f9f775db812e7a079146e56e08570d1`
- Broker: Mosquitto from the repository's pinned Linux test image

| Capability | JS → modern | Modern → JS | Legacy → modern | Modern → legacy | Gate |
|---|---|---|---|---|---|
| Advertise | Compatible | Compatible with normalization | Compatible | Not tested | PR |
| Deadvertise | Not tested | Compatible with normalization | Compatible | Not tested | PR |
| Discover / Resolve | Not tested | Compatible with normalization | Compatible | Not tested | PR |
| Query / Retrieve | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Update / Complete | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Call / Return | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Channel | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Identity lifecycle / last will | Not tested | Not tested | Not tested | Not tested | Nightly |
| Associate / IoState / IoValue | Intentional divergence | Intentional divergence | Not tested | Not tested | Nightly |
| Decentralized logging | Not tested | Not tested | Not tested | Not tested | Nightly |
| SensorThings | Not tested | Not tested | Not tested | Not tested | Audit |

Allowed results are `Compatible`, `Compatible with normalization`, `Intentional divergence`, `Unsupported`, and `Not tested`. Any intentional divergence requires a linked decision and fixture update.

`Modern → JS` for the seven core capabilities is backed by `Tests/WireCompatibility/Reverse/`: Axoloty produces (or, for request/reply pairs, requests) against the pinned CoatyJS 2.4.0 reference agent. For the five request/reply pairs (Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return) the assertion lives in the Swift test itself, decoding CoatyJS's response and checking its fields with `#expect`. For the two one-way events (Deadvertise, Channel), `AxolotyCoreProducerTests.swift` only publishes; the decoded-semantics check instead happens in `run-axoloty-core.sh`, which greps the CoatyJS consumer process's log for its `"state":"ack"` line, itself only emitted after the consumer's own field-level match succeeds. Either way, delivery alone is never treated as sufficient. It is marked "with normalization" because dynamic identifiers and timestamps are normalized before comparison.

`JS → modern` now has one live scenario: `Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh` starts CoatyJS 2.4.0 as the producer and Axoloty (`AxolotyAdvertiseConsumerTests`) as the consumer, which asserts the decoded `AdvertiseEventSnapshot`'s `coreType`, `objectType`, `objectId`, and `name` rather than merely observing wire delivery. This was run and verified end-to-end on a macOS host directly (local Mosquitto plus `node`/`npm` running pinned `@coaty/core` outside a container), not only syntax-checked; see that directory's README for details and its current container-script verification gap. The remaining six capabilities in this column, and `Tests/WireCompatibility/Live/run-coatyjs-core.sh`, still only validate the CoatyJS-to-CoatyJS reference wire protocol with no Axoloty consumer in the loop.

Identity lifecycle / last will has nine executable live scenarios of eleven, evidenced by `Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh`. Three (`unexpected-disconnect-last-will`, `qos-0`, `graceful-deadvertise`) have both subject and observer as CoatyJS reference agents, so they are not cross-implementation evidence for either directional column. Six have **Axoloty as the genuine live subject**: `duplicate-reply` and `late-reply` (Axoloty as Call/Return initiator against pinned CoatyJS 2.4.0 as a deliberately misbehaving responder, via `run-lifecycle-call-return.sh`), and the four network-failure scenarios `offline-queueing`, `reconnect-resubscribe`, `broker-restart`, and `clean-session` (via `run-lifecycle-network.sh`, which severs and restores the subject's broker connectivity through a controllable TCP proxy — or really stops and restarts Mosquitto — and proves post-reconnect re-subscription by having Axoloty decode an Advertise probe published by pinned CoatyJS 2.4.0 only after the reconnect; `clean-session` additionally verifies proxy-decoded CONNACK `sessionPresent=false` handshakes). All were verified end-to-end natively (no `docker`/`podman` on this host), cross-referencing an independent MQTT capture against the timestamped Axoloty application log, not merely a process exit code. Getting `broker-restart` to pass exposed and fixed a real defect: `MQTTNIOClient`'s failed connect attempts never rescheduled auto-reconnect (only established-then-closed connections fire mqtt-nio's close listener), so one refused attempt against a not-yet-listening broker permanently ended reconnection. See `Tests/WireCompatibility/Lifecycle/Live/README.md` for the full disposition of every catalog scenario. `qos-1`/`qos-2` remain `unsupported` for a separate, verified reason: pinned `@coaty/core@2.4.0` hardcodes QoS 0 for every publish regardless of configuration. Legacy CoatySwift 2.4.0 is descoped as a live lifecycle subject by recorded decision: see `Tests/WireCompatibility/Audit/LegacySwiftLifecycleScopeDecision.md`.

`Legacy → modern` for Advertise, Deadvertise, and Discover/Resolve is backed by real, provenance-bound CoatySwift 2.4.0 captures generated on a macOS host (`Tests/WireCompatibility/Fixtures/coatyswift-2.4.0/*.jsonl` plus their `*.manifest.json`) and decoded by `LegacyCaptureFixtureTests.swift`, which asserts the decoded Swift event's semantic fields, not only that the capture parses. Generating these captures required two fixes to the previously unexercised macOS runner (`Tests/WireCompatibility/Legacy/macOS-runner/`), documented in that directory's README: pinned CoatySwift 2.4.0's CocoaMQTT client dispatches socket callbacks on the main queue, so the runner's blocking `Thread.sleep`/`DispatchSemaphore.wait` calls starved that queue and silently dropped every publication; and the Discover/Resolve requester and responder identities produced an identical truncated MQTT ClientID, so the broker repeatedly disconnected one side. `Modern → legacy` (Axoloty producing for a legacy CoatySwift consumer) is not implemented and remains `Not tested`; the macOS runner in this repository is a producer-only scenario driver, not a consumer.

The `contract-seed` fixtures exercise the harness only. They are supplemented, for Advertise/Deadvertise/Discover-Resolve, by the provenance-bearing legacy Swift captures described above; the remaining capabilities still need equivalent legacy and CoatyJS captures.

Reference-agent pins, build instructions, and the documented legacy Swift
platform constraint live in `ReferenceAgents/README.md`.

`Associate / IoState / IoValue` is backed by `Tests/WireCompatibility/IO/`
(T-021). The generated IOV route and ASC topic, and the required Associate
fields, are compatible in both directions; the rows are marked
`Intentional divergence` because two defects were found and recorded rather
than silently normalized. **JS → modern** is blocked by Axoloty's
`handleAssociate` force-unwrapping the optional `isExternalRoute`
(`CommunicationManager.swift:557`); pinned CoatyJS 2.4.0 never serializes
that field, so an Axoloty actor traps on a CoatyJS Associate (the decode fact
is locked in offline by `AxolotyIoAssociateTests`).
**Modern → JS** runs live (`IO/Live/run-io-associate.sh`, PASS): the CoatyJS
actor decodes the Associate and subscribes to the generated route, but
receives Axoloty's IoValue as `{"payload":42}` rather than the bare value
`42` — Axoloty wraps the value under `payload` (`IoValueEventData.encode`)
while CoatyJS publishes the raw value. Both are recorded defects pending
follow-up PRs; see
`Audit/IOAndSensorThingsDecisions.md`. `IoState` is internal (not a wire
contract) and kept. Legacy CoatySwift 2.4.0 IO directions are descoped by
`Audit/LegacySwiftIOScopeDecision.md` (no macOS/Xcode host). JS integer
IoValues exceeding 2^53 lose precision through CoatyJS's float64
(`Int64.max` round-trips as `9223372036854776000`); Axoloty preserves Int64
exactly.

`SensorThings` is `Not tested` this session. There is no
`@coaty/sensor-things` npm package and `@coaty/core@2.4.0` exports no
SensorThings types; per the audit its wire contract is ordinary Coaty object
JSON with an `objectType` of `coaty.sensorThings.*` over standard
Advertise/Channel topics, so its transport compatibility reduces to the
already-proven Advertise/Channel rows. The field-schema fixtures
(`Tests/SensorThings/` exists same-process) and cross-implementation captures
remain to be run; see `Audit/IOAndSensorThingsDecisions.md`.
