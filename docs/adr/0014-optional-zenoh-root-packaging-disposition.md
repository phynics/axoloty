---
status: accepted
---

# Keep experimental Zenoh outside the root package

This ADR records the feasibility disposition requested by
[#1001](https://github.com/phynics/axoloty/issues/1001). It supplements
[ADR 0007](./0007-zenoh-adapter-package-boundary.md) with a reproducible Linux
experiment against the current SwiftPM graph.

## Decision

Keep `AxolotyZenohCore`, `AxolotyZenoh`, and `CZenohC` in
`Packages/AxolotyZenoh`. Do not promote `AxolotyZenoh` to a root product. Defer
root promotion without blocking Core 1.0.

A root package candidate that adds the adapter product and its targets to
`Package.swift` fails the required Core-only default-build condition on a
Linux host without Zenoh installed. SwiftPM's default root build reaches the
C target, warns that it cannot find `zenohc`, and Clang then fails because
`zenoh.h` is unavailable. Building only the candidate `Axoloty` product does
succeed without Zenoh, and a public URL consumer selecting only `Axoloty` also
succeeds. Product selection is therefore possible, but it does not keep the
normal root build independent of the native dependency.

The existing separate package passes its Linux offline package suite when the
pinned native artifact is provisioned. A fresh local-checkout consumer that
selects `AxolotyZenoh` also builds, runs its binding-construction probe, and
links `libzenohc.so` from the provisioned archive. SwiftPM does not address a
package by a subdirectory of the root Git URL, so this verifies the existing
experimental checkout/path-consumer boundary, not a public root URL product.

## Evidence

The rerunnable experiment is in
[`Spikes/OptionalZenohPackaging`](../../Spikes/OptionalZenohPackaging/README.md).
It pins base commit `0c74f3ae2328a8dc1528088f7b7d3be24f7cf241`, records the
candidate root-manifest patch, and retains the baseline and candidate package
dependency and target graphs.

| Case | Result | Evidence |
|---|---|---|
| Clean candidate root default build, Linux, no native Zenoh | **Fail** | Default build compiled `CAxolotyZenoh`; Clang reported `zenoh.h` missing. |
| Candidate `Axoloty` product only, Linux, no native Zenoh | Pass | `swift build --product Axoloty` completed. SwiftPM emitted a non-fatal missing-pkg-config warning while planning the package. |
| Public root URL `Axoloty` consumer, Linux, no native Zenoh | Pass | Fresh resolution at commit `0c74f3ae2328a8dc1528088f7b7d3be24f7cf241`; debug and release builds and linked executions passed. |
| Public root URL `AxolotyWire` consumer, Linux, no native Zenoh | Pass | Same fresh consumer; debug and release builds and linked executions passed. Wire-only logs contain no host runtime target compilation. |
| Experimental checkout consumer selecting `AxolotyZenoh`, Linux, pinned native Zenoh | Pass | `zenoh-offline-package` provisioned `zenoh-c 1.10.0` and passed; external probe linked and ran. `ldd` resolved `libzenohc.so` from the provisioned `unpacked/lib` directory. |
| Canonical Core verification, Linux, no Zenoh provisioning | Pass | `make test-tier TIER=ci` and `make verify`; see completion evidence recorded with #1001. The candidate is never in the production graph. |
| macOS best-effort | Untested | No macOS run was performed for this disposition. |

The native positive uses the pinned Linux x86_64 archive
`zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone.zip`, SHA-256
`1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1`, as
specified by [the Zenoh dependency record](../dependencies/zenoh.md). No Rust
build was involved. The consumer probe constructs `ZenohBinding` but does not
start a session or router. The offline package tier covers the package's
router-free tests; no live-router or device behavior is claimed here.

The public Core and Wire consumer resolution downloads the root package graph,
which includes declared SwiftPM dependencies used by other products. This
fetch does not cause native Zenoh compilation or linking. Selecting only
`AxolotyWire` continues to avoid host target compilation.

## Consequences

- Root package consumers and canonical Core verification remain independent
  from the native Zenoh archive.
- The six stable root products remain unchanged. Zenoh remains experimental
  under ADR 0012, and promotion requires a new feasibility and product decision.
- External host consumers of experimental Zenoh use the separate package from
  a checkout and provide the pinned `zenoh-c` provisioning documented in
  [`docs/dependencies/zenoh.md`](../dependencies/zenoh.md).
- This disposition makes no Zenoh graduation, cross-profile, firmware
  qualification, or release claim.
