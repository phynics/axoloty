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
