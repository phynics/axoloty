# Performance and Resource Budgets

Status: defines the versioned host/device budgets and regression policy. The
Phase 4 gate split uses entry-evidence gates (prerequisites
for reclosing Phase 3 / beginning Phase 4) and completion gates (Phase 4
scope, issue #277).

> **Provisional state.** The checked-in manifest is currently
> `approvalStatus: "provisional"`. Host latency and binary-size baselines
> are measured but their budgets still await a second clean run (`#303`).
> The C surrogate (`#302`) that did not exercise production AxolotyWire
> Swift interfaces is now recorded only as historical evidence. Production
> Embedded Swift measurements for the `esp32c6-mqtt` profile (JSON) are
> recorded in the manifest; the `esp32c6-zenoh` profile is pending the CBOR
> codec decision. Issue `#322` is closed; final per-profile budget
> re-derivation is tracked in `#987` and phynics/axoloty-embedded#63.
> The manifest may only move to `approved` once host budgets are populated
> and every device profile satisfies each approval gate enforced by
> `Tests/Support/checks/check-budget-manifest.sh`. No host/device numbers were
> fabricated for this provisional snapshot.

## Budget manifest

The machine-readable budget manifest lives at
`Benchmarks/Baselines/budget-manifest.json`. It is keyed by environment
(host, esp32c6-mqtt, esp32c6-zenoh; each device profile is its own
environment), toolchain, compiler, optimization mode, corpus version,
and module API version. `Tests/Support/checks/check-budget-manifest.sh` validates
its structure and approval state; `Tests/Support/selftests/test-check-budget-manifest.sh`
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
benchmark as `approvalEligible: false`, superseded by production Embedded
Swift evidence tracked in `#987`, and
retained only as historical engineering data. It preserves the C-surrogate
latency and resource readings so the prior numbers remain available for
comparison; no environment uses them as a budget source. The validator
rejects any manifest where a historical-evidence entry claims
`approvalEligible: true`, regardless of `approvalStatus`.

### Required fingerprint fields

Every environment (`host`, `esp32c6-mqtt`, `esp32c6-zenoh`) carries a
`fingerprint` object
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
  ESP32-C6 by the device `axoloty_heap_trace_*` gate owned by
  `phynics/axoloty-embedded`
  and on the host by `make benchmark-wire-allocation`, which profiles a warmed
  decode + static-route pass under `heaptrack` and asserts that total allocation
  calls do not grow with the iteration count (zero per-message allocation).

## Host wire latency budgets

Measured by `make benchmark-wire` (5 runs, 30 samples per operation,
calibrated batches ≥ 250ms). p50/p95 in nanoseconds.

| Operation | Measured p50 | Measured p95 | Budget p50 | Budget p95 | Status |
|-----------|-------------|-------------|-----------|-----------|--------|
| topicParse | 120ns | 157ns | pending | pending | measured |
| dtoDecode | 2,040ns | 2,367ns | pending | pending | measured |
| dtoEncode | 2,316ns | 2,866ns | pending | pending | measured |
| borrowedValidation | 133ns | 191ns | pending | pending | measured |
| combinedParseDecode | 2,189ns | 2,274ns | pending | pending | measured |

**Host latency budget formula:** `ceil(max(clean run 1, clean run 2) × 1.5)`
for both p50 and p95 (50% headroom over the worst clean run). Populate by
running `make benchmark-wire` on the NixOS host.

## ESP32-C6 device budgets

Measured on the physical ESP32-C6 (QFN40, rev v0.0, 160MHz, 4MB flash) by the
device benchmark now owned by `phynics/axoloty-embedded`. Each device profile
is its own manifest environment (`esp32c6-mqtt`, `esp32c6-zenoh`) and
declares `implementation: "embedded-swift"`; an approved manifest must
identify this implementation (the C surrogate is never approval-eligible).
p50/p95 in microseconds.

### Production Embedded Swift measurements

The `esp32c6-mqtt` (JSON, MQTT over Wi-Fi) profile carries production
Embedded Swift measurements from `embedded-swift-smoke-v2` (2026-10-10,
Core `68e46c7`, `axoloty-embedded` `49fdf44`, image `01a9145a…570b`,
661,936 B). The harness does 1,000 warm-up passes, sizes each batch to at
least 250 ms, subtracts loop overhead, and takes 30 samples over the 39-case
corpus with no serial I/O in the timed window; p50 and p95 differ by 3 ns and
repeat exactly across runs. These are measurements, not upper bounds.

The `esp32c6-zenoh` (CBOR, Zenoh) profile is `pending-baseline`: the CBOR
codec decision (#977) has not yet produced device numbers. Per the
2026-10-11 decision, the Zenoh budgets are re-derived from CBOR
measurements, while the JSON numbers below remain the `esp32c6-mqtt`
baseline.

#### `esp32c6-mqtt` latency

| Operation | Measured p50 | Measured p95 | Budget p50 | Budget p95 |
|-----------|-------------|-------------|-----------|-----------|
| topicParse | 9.698µs | 9.698µs | 20µs | 20µs |
| dtoDecode | 203.786µs | 203.789µs | 408µs | 408µs |
| dtoEncode | 249.521µs | 249.551µs | 500µs | 500µs |
| borrowedValidation | 10.308µs | 10.308µs | 21µs | 21µs |
| combinedParseDecode | 235.810µs | 235.841µs | 472µs | 472µs |

**Device latency budget formula:** `ceil(max(power-cycle run 1, run 2) × 2)`
(100% headroom) to account for temperature variation, flash access
patterns, and watchdog interference. The `esp32c6-mqtt` budgets are
derived from the production smoke measurements. The JSON decode cost is
about 34× the retired C-surrogate figure and that gap is tracked in
phynics/axoloty-embedded#66; the budget records the current production
cost so it fails on further regression. The validator enforces
`budgetP50us > measuredP50us` and `budgetP95us > measuredP95us`.

#### `esp32c6-mqtt` resources

| Resource | Measured | Budget | Formula |
|----------|---------|--------|---------|
| Free heap | 228,332 bytes | ≥ 182,665 bytes | `floor(worst observed minimum × 0.8)` |
| Min free heap | 226,276 bytes | ≥ 181,020 bytes | `floor(worst observed minimum × 0.8)` |
| Stack high-water | 2,648 bytes | ≥ 2,118 bytes | `floor(worst observed minimum × 0.8)` |
| Sustained rate | pending | ≥ 90 msg/s | 100 msg/s for 10 min; approved only at ≥ 125 msg/s measured clean capacity |
| Flash image | 661,936 bytes | ≤ 794,324 bytes (< 2,097,152 partition) | `ceil(worst observed size × 1.2)` |

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
also equal `0`. The production `esp32c6-mqtt` hot path measured `0`
allocations.

### Size limits

| Input | Limit | Behavior |
|-------|-------|----------|
| Payload | Axoloty limit: 2,048 bytes (static runtimes may select a smaller capacity) | Accepted at the selected limit, rejected above it; values above 2,048 are never accepted. Coaty does not impose this ceiling, so this is an intentional divergence. |
| Topic | Axoloty limit: 256 bytes | Accepted at 256 bytes and rejected at 257 bytes. MQTT and Coaty do not impose this ceiling, so this is an intentional compatibility divergence. |

The subscriber and family-capacity rows were removed in 0.8.0 together with
the `WireBufferConfig` constants that named them; nothing enforced those
values. Protocol state capacity is a `ProtocolBufferConfig` preset chosen per
runtime.

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

1. **`clean-cross-build-flash`** — `make embedded-swift-flash` and `make
   embedded-device-smoke` succeed from a clean checkout (pass-fail).
2. **`max-size-wire-pass`** — `make benchmark-wire-bounds` passes with
   all 36 bounds tests green (numeric).
3. **`no-reset-watchdog-race-exhaustion`** — the device benchmark
   completes without watchdog reset, heap exhaustion, or stack overflow
   (pass-fail).
4. **`min-heap-stack-headroom`** — the production `esp32c6-mqtt`
   Embedded Swift free heap ≥ 181,020 bytes; stack high-water ≥ 2,118 bytes
   (numeric).
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
make test-one FILTER='AxolotyCheckTests'
make verify
make benchmark-wire
make benchmark-wire-allocation
make benchmark-wire-bounds
make test-tier TIER=ci && make test-tier TIER=wire
sh Tests/Support/checks/check-budget-manifest.sh
sh Tests/Support/selftests/test-check-budget-manifest.sh
sh Tests/Support/checks/check-benchmark-wire-allocation.sh
sh Tests/Support/selftests/test-check-benchmark-wire-allocation.sh
```

The Phase 3 (#276) closure and Phase 4 entry require the
entry-evidence gates (and the manifest validator) to pass.
