# Performance and Resource Budgets

Status: implements issue #303. Converts measured host/device evidence
from #299–#302 into versioned budgets, defines regression policy, and
splits the Phase 4 kill gates into entry-evidence gates (prerequisites
for reclosing Phase 3 / beginning Phase 4) and completion gates (Phase 4
scope, issue #277).

> **Provisional state.** The checked-in manifest is currently
> `approvalStatus: "provisional"`. Host latency and binary-size baselines
> are still pending (`#303`) and the ESP32-C6 device measurements
> originate from a C surrogate (`#302`) that did not exercise production
> AxolotyWire Swift interfaces; production Embedded Swift device evidence
> is tracked in `#322`. The manifest may only move to `approved` once
> host baselines are populated and Embedded Swift device evidence
> satisfies every approval gate enforced by
> `Tests/Support/check-budget-manifest.sh`. No host/device numbers were
> fabricated for this provisional snapshot.

## Budget manifest

The machine-readable budget manifest lives at
`Benchmarks/Baselines/budget-manifest.json`. It is keyed by environment
(host, esp32c6), toolchain, compiler, optimization mode, corpus version,
and module API version. `Tests/Support/check-budget-manifest.sh` validates
its structure and approval state; `Tests/Support/test-check-budget-manifest.sh`
is the negative self-test suite.

### Provisional vs approved

The manifest carries a top-level `approvalStatus` field with one of two
values:

- **`provisional`** — baselines are still being collected. Pending fields
  (`pending-baseline` status, null `p50ns`/`p95ns`, null byte counts,
  empty fingerprint strings, null `sourceRun`) are permitted. The
  validator still enforces structural rules: device latency headroom,
  resource budgets, exact-zero allocation, partition safety, kill-gate
  counts, host dependency closure, and the C-surrogate eligibility rule.
- **`approved`** — every approval gate must pass. No `pending-baseline`
  status, no null measured/budget numbers, non-empty fingerprints, a
  non-empty device `sourceRun`, all mandatory device metrics present,
  and sustained-rate capacity headroom ≥ 125 msg/s. A mismatched
  fingerprint is reported by the benchmark harness but does not fail
  this structural validator, and must never overwrite an existing
  matching-fingerprint baseline.

### Historical evidence (C surrogate)

The `historicalEvidence` section records non-approval-eligible prior
runs. The `esp32c6-c-surrogate` entry marks the issue #302 C surrogate
benchmark as `approvalEligible: false`, superseded by `#322`, and
retained only as historical engineering data. The validator rejects any
manifest where a historical-evidence entry claims `approvalEligible:
true`, regardless of `approvalStatus`.

### Required fingerprint fields

Every environment (`host`, `esp32c6`) carries a `fingerprint` object
with these keys, all of which must be non-empty strings when
`approvalStatus` is `approved` (empty strings are permitted while
`provisional`):

`boardModel`, `boardRevision`, `cpuFrequencyMhz`, `swiftCompilerVersion`,
`idfSwiftVersion`, `espIdfVersion`, `gccBinutilsVersion`,
`optimizationMode`, `compilerFlags`, `containerImageDigest`,
`corpusVersion`, `corpusHash`, `moduleApiVersion`, `gitCommit`,
`gitClean`, `benchmarkHarnessVersion`, `freeRtosTickRate`,
`taskStackSizes`.

Fingerprints identify the exact environment a baseline was recorded
against; baseline comparisons are matching-fingerprint only.

## Noise and regression policy

- **Matching-fingerprint comparisons only.** Baselines are compared only
  when the environment fingerprint matches. Mismatched fingerprints are
  reported but do not fail or overwrite a matching baseline.
- **Noisy runs fail collection.** Relative MAD (Median Absolute
  Deviation) must be ≤ 5% for p50/p95 across 5 runs. Allocation counts
  must have exactly zero variance. A noisy run fails rather than
  updating a baseline.
- **Budget increases require evidence and approval.** A budget increase
  must cite a measured regression and be approved in a PR that updates
  the manifest. Silent regeneration is not permitted.
- **Failed budgets open a bounded finding.** When a budget fails, a
  finding issue is opened with a deadline. Optimization may proceed only
  after the finding is triaged.
- **Zero-allocation hot paths retain an exact-zero budget.** The
  borrowed decode/routing steady-state window must record zero
  allocations (`hotPathAllocations.budget == 0`; `measured == 0` when
  approved). Any non-zero count is a failure, not drift. This is verified on
  ESP32-C6 by the device `axoloty_heap_trace_*` gate (`make benchmark-wire-device`)
  and on the host by `make benchmark-wire-allocation`, which profiles a warmed
  decode + static-route pass under `heaptrack` and asserts that total allocation
  calls do not grow with the iteration count (zero per-message allocation).

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

**Host latency budget formula:** `ceil(max(clean run 1, clean run 2) × 1.5)`
for both p50 and p95 (50% headroom over the worst clean run). Populate by
running `make benchmark-wire` on the NixOS host.

## Host binary-size budgets

Measured by `make benchmark-size` (release-mode build, stripped/unstripped
ELF bytes, section sizes, dependency closure).

| Consumer | Budget (stripped) | Status |
|----------|------------------|--------|
| AxolotyWireConsumer | pending | pending-baseline |
| AxolotyConsumer | pending | pending-baseline |

**Host binary/section-size budget formula:** `ceil(max(clean build 1,
clean build 2) × 1.2)` (20% headroom over the worst clean build).

AxolotyWireConsumer must resolve zero host packages (mqtt-nio, swift-nio,
NIOSSL, NIOTransportServices, swift-log, ErrorKit, IkigaJSON). Their
appearance is a failure, not baseline drift. `AxolotyConsumer` may carry
host dependencies.

## ESP32-C6 device budgets

Measured on the physical ESP32-C6 (QFN40, rev v0.0, 160MHz, 4MB flash)
via `make benchmark-wire-device`. The `esp32c6` environment declares
`implementation: "embedded-swift"`; an approved manifest must identify
this implementation (the C surrogate is never approval-eligible). The
provisional values below originate from the C surrogate (#302) and are
retained pending Embedded Swift evidence (#322). p50/p95 in microseconds.

### Latency

| Operation | Measured p50 | Measured p95 | Budget p50 | Budget p95 |
|-----------|-------------|-------------|-----------|-----------|
| topicParse | 2µs | 2µs | 4µs | 4µs |
| dtoDecode (advertise) | 6µs | 6µs | 12µs | 12µs |
| dtoDecode (ioValue) | 3µs | 3µs | 6µs | 6µs |
| dtoDecode (associate) | 5µs | 5µs | 10µs | 10µs |
| combinedParseDecode | 7µs | 8µs | 14µs | 16µs |

**Device latency budget formula:** `ceil(max(power-cycle run 1, run 2) × 2)`
(100% headroom) to account for temperature variation, flash access
patterns, and watchdog interference. The validator enforces
`budgetP50us > measuredP50us` and `budgetP95us > measuredP95us`.

### Resources

| Resource | Measured | Budget | Formula |
|----------|---------|--------|---------|
| Free heap | 458,684 bytes | ≥ 400,000 bytes | `floor(worst observed minimum × 0.8)` |
| Min free heap | 458,684 bytes | ≥ 400,000 bytes | `floor(worst observed minimum × 0.8)` |
| Stack high-water | 6,580 bytes | ≥ 4,000 bytes | `floor(worst observed minimum × 0.8)` |
| Sustained rate | 100 msg/s | ≥ 90 msg/s | 100 msg/s for 10 min; approved only at ≥ 125 msg/s measured clean capacity |
| Flash image | 163 KB | ≤ 1,048,576 bytes (< 2,097,152 partition) | `ceil(worst observed size × 1.2)` |

**Device resource minimum budget formula:** `floor(worst observed minimum ×
0.8)` (20% headroom below the worst observed minimum). **Device size-max
budget formula:** `ceil(worst observed size × 1.2)` (20% headroom above
the worst observed size). The validator enforces `budgetMin < measured`
and `budgetMax > measured`, plus `flashImage.budgetMax <
partitionLimitBytes`.

Mandatory device metrics when `approved`: `freeHeap`, `minFreeHeap`,
`largestFreeBlock`, `fragmentation`, `stackHighWater`, `data`, `bss`,
`iram`, `flashImage`. The `hotPathAllocations` metric must always be
present with `budget: 0` (exact-zero); when approved, `measured` must
also equal `0`.

### Size limits

| Input | Limit | Behavior |
|-------|-------|----------|
| Payload | Axoloty limit: 2,048 bytes (static runtimes may select a smaller capacity) | Accepted at the selected limit, rejected above it; values above 2,048 are never accepted. Coaty does not impose this ceiling, so this is an intentional divergence. |
| Topic | Axoloty limit: 256 bytes | Accepted at 256 bytes and rejected at 257 bytes. MQTT and Coaty do not impose this ceiling, so this is an intentional compatibility divergence. |
| maxSubscribers | 8 | 9th rejected |
| maxFamilyEntries | 16 | 17th rejected |
| maxFamilySubscribers | 4 | 5th rejected |

Each size limit must declare `overLimitRejected: true`; a hard-coded
over-limit "success" record is a validator failure.

### Sustained rate

100 msg/s for 10 minutes: zero missed messages, zero allocation in the
hot path (heap stable throughout). The sustained-rate budget is
100 msg/s, but it may only be **approved** when measured clean capacity
is ≥ 125 msg/s — modeled as the `sustainedRate.capacityHeadroomMsgPerS`
field, which must be ≥ 125 when `approved`.

## Phase 4 gate split

The prior single `phase4KillGates` array is split into two arrays whose
order encodes dependency: entry-evidence gates must pass before Phase 3
is reclosed and before Phase 4 work may claim budget compliance;
completion gates belong to Phase 4 completion (#277) and are **not**
prerequisites for beginning Phase 4.

### Phase 4 entry-evidence gates (`phase4EntryEvidenceGates`)

At least 5 gates, each with `id`, `description`, `threshold`, and
`thresholdType`:

1. **`clean-cross-build-flash`** — `make embedded-image` + `make
   embedded-device-smoke` succeed from a clean checkout (pass-fail).
2. **`max-size-wire-pass`** — `make benchmark-wire-bounds` passes with
   all 36 bounds tests green (numeric).
3. **`no-reset-watchdog-race-exhaustion`** — the device benchmark
   completes without watchdog reset, heap exhaustion, or stack overflow
   (pass-fail).
4. **`min-heap-stack-headroom`** — free heap ≥ 400,000 bytes; stack
   high-water ≥ 4,000 bytes (numeric).
5. **`sustained-rate-pass`** — 100 msg/s for 10s with zero missed
   messages and zero allocation (numeric).

### Phase 4 completion gates (`phase4CompletionGates`)

At least 4 gates:

1. **`mqtt-vertical-slice-within-budgets`** — the MQTT vertical slice
   operates within the same latency, heap, and stack budgets (pass-fail).
2. **`required-broker-backed-exchanges-pass`** — all required
   broker-backed exchange integration tests pass under deadlines
   (pass-fail).
3. **`reconnect-last-will-under-deadlines`** — reconnect and last-will
   semantics meet their configured deadlines under load (numeric).
4. **`host-axoloty-coatyjs-interoperability`** — the host Axoloty ↔
   CoatyJS reference agent wire interoperability suite passes
   (pass-fail).

Each gate has a pass/fail or numeric threshold, not a "runs once"
criterion. A gate that passes once but fails on a subsequent run blocks
Phase 4 progress until the regression is resolved.

## Validation commands

```text
make build
make verify
make benchmark-wire
make benchmark-wire-allocation
make benchmark-size
make benchmark-wire-bounds
make benchmark-wire-device
make test-wire test-wire-live
sh Tests/Support/check-budget-manifest.sh
sh Tests/Support/test-check-budget-manifest.sh
sh Tests/Support/check-benchmark-wire-allocation.sh
sh Tests/Support/test-check-benchmark-wire-allocation.sh
```

The Phase 3 (#276) closure and Phase 4 entry require the
entry-evidence gates (and the manifest validator) to pass.
