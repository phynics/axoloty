# Wire compatibility matrix

Reference versions must be pinned before captured fixtures become normative:

- Modern Swift: current `main`
- Legacy Swift: `coatyio/coaty-swift` tag `2.4.0` at `20a97b29832758fb771ac79fd5f7ae36cff69403`
- CoatyJS: `@coaty/core@2.4.0` from tag `v2.4.0` at `4a7716815f9f775db812e7a079146e56e08570d1`
- Broker: Mosquitto from the repository's pinned Linux test image

| Capability | JS → modern | Modern → JS | Legacy → modern | Modern → legacy | Gate |
|---|---|---|---|---|---|
| Advertise / Deadvertise | Planned | Planned | Planned | Planned | PR |
| Discover / Resolve | Planned | Planned | Planned | Planned | PR |
| Query / Retrieve | Planned | Planned | Planned | Planned | PR |
| Update / Complete | Planned | Planned | Planned | Planned | PR |
| Call / Return | Planned | Planned | Planned | Planned | PR |
| Channel | Planned | Planned | Planned | Planned | PR |
| Identity lifecycle / last will | Planned | Planned | Planned | Planned | Nightly |
| Associate / IoState / IoValue | Decision needed | Decision needed | Decision needed | Decision needed | Nightly |
| Decentralized logging | Planned | Planned | Planned | Planned | Nightly |
| SensorThings | Decision needed | Decision needed | Decision needed | Decision needed | Audit |

Allowed results are `Compatible`, `Compatible with normalization`, `Intentional divergence`, `Unsupported`, and `Not tested`. Any intentional divergence requires a linked decision and fixture update.

The `contract-seed` fixtures exercise the harness only. They are replaced or supplemented by provenance-bearing captures from legacy Swift and CoatyJS in T-017/T-018.

Reference-agent pins, build instructions, and the documented legacy Swift
platform constraint live in `ReferenceAgents/README.md`.
