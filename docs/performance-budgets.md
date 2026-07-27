# Performance and Resource Budgets

Status: implements issue #303. Converts measured host/device evidence
from #299–#302 into approved versioned budgets, defines regression
policy, and sets Phase 4 kill gates.

## Budget manifest

The machine-readable budget manifest lives at
`Benchmarks/Baselines/budget-manifest.json`. It is keyed by environment
(host, esp32c6), toolchain, compiler, optimization mode, corpus version,
and module API version. `make test-support` validates its structure and
completeness.

Host baselines are marked `pending-baseline` until `make benchmark-wire`
and `make benchmark-size` are run on the NixOS host to populate the
checked-in baseline files. Device baselines are populated from the
verified on-device run (issue #302).

## Noise and regression policy

- **Matching-fingerprint comparisons only.** Baselines are compared only
  when the environment fingerprint (compiler, target triple, CPU, kernel,
  corpus hash, commit) matches. Mismatched fingerprints are reported but
  do not fail.
- **Noisy runs fail collection.** Relative MAD (Median Absolute Deviation)
  must be ≤ 5% for p50/p95 across 5 runs. Allocation counts must have
  exactly zero variance. A noisy run fails rather than updating a
  baseline.
- **Budget increases require evidence and approval.** A budget increase
  must cite a measured regression and be approved in a PR that updates
  the manifest. Silent regeneration is not permitted.
- **Failed budgets open a bounded finding.** When a budget fails, a
  finding issue is opened with a deadline. Optimization may proceed only
  after the finding is triaged.
- **Zero-allocation hot paths retain an exact-zero budget.** The
  borrowed decode/routing steady-state window must record zero
  allocations. Any non-zero count is a failure, not drift.

## Host wire latency budgets

Measured by `make benchmark-wire` (5 runs, 30 samples per operation,
calibrated batches ≥ 250ms). p50/p95 in nanoseconds.

| Operation | Budget p50 | Budget p95 | Status |
|-----------|-----------|-----------|--------|
| topicParse | pending | pending | pending-baseline |
| dtoDecode | pending | pending | pending-baseline |
| dtoEncode | pending | pending | pending-baseline |
| borrowedValidation | pending | pending | pending-baseline |
| combinedParseDecode | pending | pending | pending-baseline |

Budget ceilings = measured p50/p95 × 1.5 (50% headroom). Populate by
running `make benchmark-wire` on the NixOS host.

## Host binary-size budgets

Measured by `make benchmark-size` (release-mode build, stripped/unstripped
ELF bytes, section sizes, dependency closure).

| Consumer | Budget (stripped) | Status |
|----------|------------------|--------|
| AxolotyWireConsumer | pending | pending-baseline |
| AxolotyConsumer | pending | pending-baseline |

AxolotyWireConsumer must resolve zero host packages (mqtt-nio, swift-nio,
NIOSSL, NIOTransportServices, swift-log, ErrorKit, IkigaJSON). Their
appearance is a failure, not baseline drift.

## ESP32-C6 device budgets

Measured on the physical ESP32-C6 (QFN40, rev v0.0, 160MHz, 4MB flash)
via `make benchmark-wire-device`. p50/p95 in microseconds.

### Latency

| Operation | Measured p50 | Measured p95 | Budget p50 | Budget p95 |
|-----------|-------------|-------------|-----------|-----------|
| topicParse | 2µs | 2µs | 4µs | 4µs |
| dtoDecode (advertise) | 6µs | 6µs | 12µs | 12µs |
| dtoDecode (ioValue) | 3µs | 3µs | 6µs | 6µs |
| dtoDecode (associate) | 5µs | 5µs | 10µs | 10µs |
| combinedParseDecode | 7µs | 8µs | 14µs | 16µs |

Budget ceilings = measured × 2 (100% headroom) to account for
temperature variation, flash access patterns, and watchdog interference.

### Resources

| Resource | Measured | Budget (minimum) | Headroom |
|----------|---------|-----------------|----------|
| Free heap | 458,684 bytes | 400,000 bytes | 58,684 bytes (13%) |
| Min free heap | 458,684 bytes | 400,000 bytes | 58,684 bytes (13%) |
| Stack high-water | 6,580 bytes | 4,000 bytes | 2,580 bytes (39%) |
| Sustained rate | 100 msg/s | 100 msg/s | 0 (at target) |
| Flash image | 163KB | 1MB (partition) | 85% free |

### Size limits

| Input | Limit | Behavior |
|-------|-------|----------|
| Payload | 512 bytes | Accepted at limit, rejected at 513 |
| Topic | 128 bytes | Accepted at limit, rejected at 129 |
| maxSubscribers | 8 | 9th rejected |
| maxFamilyEntries | 16 | 17th rejected |
| maxFamilySubscribers | 4 | 5th rejected |

### Sustained rate

100 msg/s for 10 seconds: 1000/1000 messages succeeded, zero missed,
zero allocation (heap stable at 458,684 bytes throughout). The
sustained-rate budget is 100 msg/s with zero missed messages and zero
allocation in the hot path.

## Phase 4 kill gates

Phase 4 (#277) may begin only when all of the following pass:

1. **Clean cross-build/flash.** `make embedded-image` + `make
   embedded-device-smoke` succeed from a clean checkout.
2. **Maximum-size local wire pass.** `make benchmark-wire-bounds` passes
   with all 36 bounds tests green.
3. **No reset/watchdog/race/resource exhaustion.** The device benchmark
   (`make benchmark-wire-device`) completes without watchdog reset (other
   than expected watchdog warnings during tight benchmark loops), heap
   exhaustion, or stack overflow.
4. **Minimum approved heap/stack headroom.** Free heap ≥ 400,000 bytes;
   stack high-water ≥ 4,000 bytes.
5. **Sustained-rate pass.** 100 msg/s for 10 seconds with zero missed
   messages and zero allocation.
6. **MQTT vertical-slice within budgets.** (Phase 4 scope) The MQTT
   vertical slice operates within the same latency, heap, and stack
   budgets defined above.

Each kill gate has a pass/fail threshold, not a "runs once" criterion.
A gate that passes once but fails on a subsequent run blocks Phase 4
progress until the regression is resolved.

## Validation commands

```text
make build
make test
make benchmark-wire
make benchmark-size
make benchmark-wire-bounds
make benchmark-wire-device
make test-wire-all
```

All must pass for Phase 3 (#276) to close.
