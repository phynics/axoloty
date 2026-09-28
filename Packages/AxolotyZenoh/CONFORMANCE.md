# Axoloty Zenoh façade conformance

`Sources/AxolotyZenohContract/Resources/axoloty-zenoh-facade-v2.json` is the
single shared fixture artifact for the `axoloty_zenoh_*` C ABI. The Swift test
target at `ContractSuite/` decodes these vectors; test bodies do not contain
carrier-specific branches. `CAxolotyZenoh` and `CAxolotyZenohTestSupport` are
the harness seam: the former provides the façade ABI and the latter supplies
an unrestricted test publisher for inbound overflow cases. A backend
conformance run selects implementations for these stable target/module names
without changing test assertions or fixtures.

## Versioning and consumption

The artifact uses SemVer in `contractVersion`. Patch releases correct fixture
metadata without changing expected behavior. Minor releases add optional
vectors or clarify requirements without weakening existing assertions. Major
releases may change ABI and requirements. Version 2 changes subscribe to return
an opaque handle and scopes unsubscribe, polling, queue depth, and overflow
counters to that handle. Version 2.1 adds the synchronous connected-router count
query and its router-presence vectors without changing prior requirements. A
conformance report MUST identify both this contract version and the exact
Axoloty Git revision that supplied it.

`phynics/axoloty-embedded#8` consumes the artifact by pinning the Axoloty Git
revision and extracting only the contract directory, for example:

```sh
git archive <axoloty-commit> Packages/AxolotyZenoh/CONFORMANCE.md \
  Packages/AxolotyZenoh/ContractSuite \
  Packages/AxolotyZenoh/Sources/AxolotyZenohContract | tar -x
```

This pins the test bodies, fixture, and rules to immutable source without
making anything under `Tests/`, the root `.build`, or a parent-directory layout
available to firmware consumers. `ContractSuite/` is the SwiftPM test-target
path so the embedded conformance runner can compile the same source against its
local harness modules. The tradeoff is that the embedded conformance runner
must explicitly refresh its revision pin when the contract changes; it must not
copy and maintain a second contract. **`phynics/axoloty-embedded#8` must re-pin
the Axoloty revision that contains contract 2.1.0 and the connected-router query;
pico must implement the same query and vectors, or record a divergence with
capture or test evidence.** The `axoloty-zenoh-facade-v2.json` filename remains
because the major ABI generation is still version 2; the additive minor version
is identified by `contractVersion`.

## Fixed subscriber and queue bounds

`AXOLOTY_ZENOH_MAX_SUBSCRIBERS` is eight per session. It is a power of two so
three low bits encode a subscriber slot in opaque generation-guarded handles.
Two slots accommodate the profile-interest expressions
`coaty/3/<namespace>/*/*` and `coaty/3/<namespace>/*/*/*`; six remain for exact
external routes. The host configuration therefore caps
`maximumExternalRoutes` at six instead of the former 64.

Each subscriber has its own four-frame queue. At the maximum 256-byte key and
2048-byte payload bounds, the queue's fixed byte arrays occupy
`4 × (256 + 2048) = 9,216` bytes per subscription. Four per-frame sequence
counters and frame lengths/validity metadata add bounded overhead; a further
256-byte key copy is retained per slot. Thus eight subscriptions require at
least `8 × (9,216 + 256) = 75,776` bytes of fixed key/payload arrays per
session, plus bounded metadata and Zenoh subscriber handles. Queue capacity in
the host binding is per subscription, not shared across the session.

The façade supports four sessions. Its maximum fixed key/payload array cost is
therefore `4 × 75,776 = 303,104` bytes (about 303 KB), plus bounded metadata and
Zenoh subscriber handles across those sessions.

## Required behavior

Both implementations of the façade ABI must satisfy all assertions in the
shared contract suite. In particular:

- lifecycle operations open, report state, close, reject repeated close, and
  allow a closed slot to be reopened;
- publish and subscribe preserve key and payload bytes, including zero and
  non-UTF-8 payload bytes;
- different sessions can subscribe independently;
- one session can hold both profile-interest shapes and an exact external route
  at once, each with an independent queue and counters;
- unsubscribing one handle leaves the other subscriptions active;
- subscriber saturation and stale or foreign handles fail without partial
  mutation;
- queue saturation drops newest frames and reports the bounded drop count;
- over-limit inbound keys and payloads are discarded and reported, never
  truncated;
- an unreachable session returns the façade transport failure and releases
  its slot.
- a freshly opened peer session reports zero connected routers with `OK` when
  no router is present; a closed session returns `NOT_OPEN`; null or foreign
  handles and null output pointers return `INVALID_ARGUMENT`.

## zenoh-c test mapping

| Contract operation | Test assertion |
|---|---|
| Open/close | `openStateClose` |
| Publish | `copiesBorrowedPayload` |
| Subscribe | `subscribePollRoundTripAndUnsubscribe` |
| Unsubscribe | `subscribePollRoundTripAndUnsubscribe` |
| Round-trip | `subscribePollRoundTripAndUnsubscribe` |
| Binary payload | `subscribePollRoundTripAndUnsubscribe` and `copiesBorrowedPayload` |
| Multiple subscribers | `multipleSubscribersReceiveSameFrame` |
| Concurrent subscriptions and independent removal | `concurrentSubscriptionSlots` |
| Queue overflow | `fullQueueDropsNewest` |
| Key overflow | `oversizedFramesAreNotTruncated` |
| Payload overflow | `oversizedFramesAreNotTruncated` |
| Session failure | `unreachableClientCleansUp` |
| Reopen | `capacitySaturationAndRelease` |
| Connected-router presence | `connectedRouterCount`, `connectedRouterCountInvalidArguments` |

The suite documents no backend-specific tolerances. Divergence status:

> Existing vectors remain to be qualified by phynics/axoloty-embedded#8. Contract 2.1.0 requires its pico implementation to provide the same connected-router query and vectors; if it cannot, record the divergence with evidence (no pico-backend comparison was performed here).

## MQTT and Zenoh protocol trace parity (#811)

`AxolotyProtocolTraceTestSupport` owns one trace schema, fixture corpus,
canonical observations, and runtime replay adapter. The Zenoh tests reuse this
module for 34 protocol-eligible traces. They run each trace through `MQTTBinding`
with the root package's in-process broker and through `ZenohBinding` with an
injected session. They do not start `zenohd`.

The adapter suppresses startup and state-seeding publications. It sends outbound
actions from scenario steps through each binding. The comparison ignores
carrier keys, timestamps, and transport identifiers. It compares actions,
families, normalized correlation labels, payloads, route classes, rejections,
and protocol state.

The parity run uses 34 of the 35 stored traces. It covers all 13 closed-profile
families (`ADV`, `DAD`, `CHN`, `ASC`, `IOV`, `DSC`, `RSV`, `QRY`, `RTV`, `UPD`,
`CPL`, `CLL`, `RTN`), plus malformed, duplicate, saturation, correlation,
deadline, and external-route cases. It omits only `negative-payload-limit`:
that fixture exceeds Zenoh's fixed 2,048-byte receive-buffer maximum and is
rejected before it reaches `AxolotyProtocol`. The root trace suite continues to
verify that case against the shared protocol implementation. It is outside
cross-carrier protocol-observation parity because it tests a transport-boundary
limit. The parity check does not tolerate differences in protocol observations.

The MQTT-versus-Zenoh route-classification matrix required by #808/#811 is:

| Equivalent route bytes | MQTT | Zenoh | Result |
|---|---|---|---|
| Active `coaty/3/node/IOV/...` | Coaty | Coaty | Equivalent |
| `coaty/3/node/ADV/...` | Unrelated | Unrelated | Equivalent |
| `coaty/3/other/IOV/...` | Unrelated | Unrelated | Equivalent |
| `legacy/source/value` | External | External | Equivalent |
| `bad//route` | Unrelated | Unrelated | Equivalent |
| `bad/+/route` | Unrelated | Unrelated | Equivalent |
| `bad/*/route` | External | Unrelated | Deliberate divergence |
| One non-UTF-8 key byte (`FF`) | External | External | Equivalent classification; Zenoh frame admission separately rejects non-UTF-8 keys |

The `*` row is deliberate: MQTT's route classifier permits this byte in an
otherwise external topic, while Zenoh rejects wildcard key expressions and
external activation fails before subscription. The test asserts each side's
documented result and excludes only this row from classification equality.
This adapter-level divergence does not relax protocol trace equality. The
non-UTF-8 row compares classifier results only; a Zenoh inbound frame must
still be valid UTF-8 before it can become a runtime route.

### Lifecycle last will

| Behavior | MQTT | Zenoh | Result |
|---|---|---|---|
| Unclean-disconnect Deadvertise (runtime `RuntimeTransportLastWill`) | Installed as the broker will | Accepted and discarded (`_ = lastWill`) | Deliberate divergence |

`ZenohBinding.start(receive:lastWill:)` ignores the will because the v1 client
profile is put/subscriber only, and Zenoh has no broker-published will. Epic
[#796](https://github.com/phynics/axoloty/issues/796) keeps Zenoh liveliness
out of v1 scope. Graceful shutdown still publishes Deadvertise on both
carriers. Only unclean-disconnect notification differs. The divergence is
outside protocol trace parity, because traces do not model broker-published
wills. See `docs/transports/zenoh.md`.
