# Wire compatibility matrix

Reference versions must be pinned before captured fixtures become normative:

- Modern Swift: current `main`
- Legacy Swift: `coatyio/coaty-swift` tag `2.4.0` at `20a97b29832758fb771ac79fd5f7ae36cff69403`
- CoatyJS: `@coaty/core@2.4.0` from tag `v2.4.0` at `4a7716815f9f775db812e7a079146e56e08570d1`
- Broker: Mosquitto from the repository's pinned Linux test image

| Capability | JS → modern | Modern → JS | Legacy → modern | Modern → legacy | Gate |
|---|---|---|---|---|---|
| Advertise | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Deadvertise | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Discover / Resolve | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Query / Retrieve | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Update / Complete | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Call / Return | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Channel | Not tested | Compatible with normalization | Not tested | Not tested | PR |
| Identity lifecycle / last will | Not tested | Not tested | Not tested | Not tested | Nightly |
| Associate / IoState / IoValue | Decision needed | Decision needed | Decision needed | Decision needed | Nightly |
| Decentralized logging | Not tested | Not tested | Not tested | Not tested | Nightly |
| SensorThings | Decision needed | Decision needed | Decision needed | Decision needed | Audit |

Allowed results are `Compatible`, `Compatible with normalization`, `Intentional divergence`, `Unsupported`, and `Not tested`. Any intentional divergence requires a linked decision and fixture update.

`Modern → JS` for the seven core capabilities is backed by `Tests/WireCompatibility/Reverse/`: Axoloty produces (or, for request/reply pairs, requests) against the pinned CoatyJS 2.4.0 reference agent. For the five request/reply pairs (Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return) the assertion lives in the Swift test itself, decoding CoatyJS's response and checking its fields with `#expect`. For the two one-way events (Deadvertise, Channel), `AxolotyCoreProducerTests.swift` only publishes; the decoded-semantics check instead happens in `run-axoloty-core.sh`, which greps the CoatyJS consumer process's log for its `"state":"ack"` line, itself only emitted after the consumer's own field-level match succeeds. Either way, delivery alone is never treated as sufficient. It is marked "with normalization" because dynamic identifiers and timestamps are normalized before comparison. `JS → modern` has no live coverage yet: `Tests/WireCompatibility/Live/run-coatyjs-core.sh` only validates the CoatyJS-to-CoatyJS reference wire protocol and has no Axoloty consumer in the loop.

Identity lifecycle / last will has one executable live scenario (`unexpected-disconnect-last-will`, evidenced by `Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh`), but its subject and its observer are both CoatyJS reference agents, so it is not yet cross-implementation evidence for either directional column; see that directory's README for the full disposition of every catalog scenario. The remaining ten lifecycle scenarios are recorded as `unsupported` (documented reference-fixture or harness limitation), never as passing.

The `contract-seed` fixtures exercise the harness only. They are replaced or supplemented by provenance-bearing captures from legacy Swift and CoatyJS in T-017/T-018.

Reference-agent pins, build instructions, and the documented legacy Swift
platform constraint live in `ReferenceAgents/README.md`.
