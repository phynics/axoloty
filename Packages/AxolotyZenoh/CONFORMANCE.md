# Axoloty Zenoh façade conformance

`Sources/AxolotyZenohContract/Resources/axoloty-zenoh-facade-v1.json` is the
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
releases may change or remove requirements. A conformance report MUST identify
both this contract version and the exact Axoloty Git revision that supplied it.

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
copy and maintain a second contract.

## Required behavior

Both implementations of the façade ABI must satisfy all assertions in the
shared contract suite. In particular:

- lifecycle operations open, report state, close, reject repeated close, and
  allow a closed slot to be reopened;
- publish and subscribe preserve key and payload bytes, including zero and
  non-UTF-8 payload bytes;
- multiple subscribers each receive the same publication;
- queue saturation drops newest frames and reports the bounded drop count;
- over-limit inbound keys and payloads are discarded and reported, never
  truncated;
- an unreachable session returns the façade transport failure and releases
  its slot.

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
| Queue overflow | `fullQueueDropsNewest` |
| Key overflow | `oversizedFramesAreNotTruncated` |
| Payload overflow | `oversizedFramesAreNotTruncated` |
| Session failure | `unreachableClientCleansUp` |
| Reopen | `capacitySaturationAndRelease` |

The suite documents no backend-specific tolerances. Divergence status:

> pico leg owned by phynics/axoloty-embedded#8; not assessed here (no pico-backend comparison was performed)
