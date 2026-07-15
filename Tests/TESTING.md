# Axoloty testing strategy

Axoloty uses a layered suite. Fast, deterministic tests provide the default
development signal; broker-backed and cross-language tests prove behavior that
cannot be established in-process. CoatyJS 2.4.x is the wire-compatibility
oracle. Legacy CoatySwift is useful historical evidence, but is not a required
interop target.

The machine-readable companion to this document is
[`Support/test-tiers.json`](Support/test-tiers.json). Each directly executable
tier records its canonical Make target, and every maintained `Tests/**/test_*.py` /
`Tests/**/test-*.sh` harness self-test is mapped to exactly one owning Make
target. Validate the contract with:

```sh
python3 Tests/Support/validate_test_tiers.py
```

The validator checks tier metadata, resolves every `makeTarget` and self-test
owner against the real Makefile targets, and fails if a maintained self-test
is unmapped or owned by more than one target. It does not invoke Swift; run it
through `make test-support` for the standard Makefile path. Build and test
execution must always use the root Makefile and Podman.

## Command-to-tier map

Tiers with a direct Make target record it in the contract. The manual macOS
oracle remains host-specific. Harness self-tests live in `make test-support`,
separate from protocol-scenario execution.

| Tier | Make target | Runs Swift? | Notes |
|---|---|:---:|---|
| Smoke | `make build` | yes | Proves the package compiles and links |
| Unit | `make test-unit` | yes | `ObjectMatcherTests` |
| Module | `make test-module` | yes | Topic, payload, and registry module tests |
| Property | `make test-fuzz` | yes | Seeded `DeterministicFuzzTests` |
| Integration | `make test` | yes | Full suite against a fresh Mosquitto |
| Wire offline | `make test-wire` | yes | `WireFixtureTests` and lifecycle scenarios |
| Wire live | `make test-wire-live` | yes | Live CoatyJS interop (host-run containers) |
| Nightly | `make fuzz-long` | yes | Multi-seed fuzz campaign |
| Harness self-tests | `make test-support` | no | Fuzz runner, capture/verifier tools, tier validation |

`make test-fast` runs unit, module, property, offline-wire, and support
self-tests in one image build; `make ci` adds the full integration suite.

Nightly fuzz campaigns run from `.github/workflows/fuzz.yml` with the pinned
development image. Scheduled runs use 100,000 iterations over seeds 1, 2, 3,
and 4; manual runs may use bounded inputs and retain the finalized campaign
manifest, summary, logs, and reproducers as workflow artifacts.

## Test tiers

| Tier | Purpose | Dependencies | Default timeout | Required cadence |
|---|---|---|---:|---|
| Smoke | Prove the package builds and its smallest public path loads | Container only | 5 min | Every PR |
| Unit | Pure functions and value semantics at one type boundary | None beyond test process | 2 min | Every PR |
| Module | A subsystem through its public/internal module boundary | In-process fakes; broker only when intrinsic | 5 min | Every PR |
| Property | Generated-input invariants, round trips, and parser robustness | Seeded generator | 10 min | Every PR with a bounded corpus |
| Integration | Axoloty components collaborating through a real Mosquitto broker | Isolated broker | 10 min | Every PR |
| Wire offline | Golden topics/payloads and capture-tool correctness | Versioned fixtures | 5 min | Every PR |
| Wire live | Representative Axoloty/CoatyJS interoperability plus CoatyJS reference-wire protocol coverage | Containers, broker, CoatyJS image | 20 min | Protocol-facing PRs; full run before merge |
| Nightly | Large generated corpora, repeat runs, reconnect/failure scenarios, sanitizers when available | Full container stack | 60 min | Nightly and release candidates |
| Manual macOS oracle | Apple-platform API and transport confidence | Supported macOS/Xcode host | 30 min | Release candidates and Apple-specific changes |

### Smoke

The smoke tier builds the package in the canonical development container and
runs one minimal test that imports `Axoloty`. It catches manifest,
dependency, and basic linkage failures. It must not start a broker or download
anything after the container image and Swift dependencies are cached.

### Unit

Unit tests target deterministic transformations: matching, topic parsing and
generation, payload coding, identifiers, configuration defaults, and value
semantics. Prefer table-driven cases. A regression fix should receive a focused
test when its behavior can be expressed without sleeps, networking, or global
state.

Not every getter warrants a test. Unit tests are most valuable at branches,
boundary values, error paths, and protocol-significant transformations.

### Module

Module tests exercise a coherent subsystem through stable boundaries. Priority
modules are payload coding, communication topics, object registration, object
lifecycle, subscription routing, MQTT adapter state transitions, and logging.
Use deterministic fakes for clocks, ID sources, and transports where those are
not the subject under test. Broker-backed module tests are appropriate for the
MQTT adapter itself.

### Property and fuzz testing

Property tests complement examples; they do not replace them. Initial
properties should include:

- encode/decode preserves every supported object field;
- JSON normalization is idempotent;
- topic parse/render round trips for valid topic components;
- malformed payloads and topics fail without crashing or hanging;
- unknown JSON properties remain compatible where the protocol permits them;
- arbitrary byte input to wire parsers cannot trap;
- subscription matching agrees with a small, independent reference model.

Every generated run records its seed. PR runs use a fixed seed set and bounded
case count. Nightly runs add a time-seeded campaign and persist the seed and
smallest reduced input on failure. A minimized regression becomes a committed
example fixture before the bug is closed.

Swift-native fuzzing may be added when toolchain support is stable in the
container. Until then, deterministic generators in Swift Testing are the portable
baseline. External fuzzers must emit replayable files, never only a crash log.

For an extended, auditable campaign, use the runner beside the fuzz tests:

```sh
Tests/Fuzzing/run-fuzz.sh \
  --iterations 100000 \
  --seeds 1,2,3,4 \
  --repetitions 3 \
  --jobs 4 \
  --output .testing/fuzz
```

The runner assigns cases round-robin to `--jobs` workers (two by default). Each worker builds
its Swift test products once in a private scratch path, then invokes its
assigned seed/repetitions with `swift test --skip-build`. This avoids both a
rebuild per case and contention on SwiftPM's shared build database, while
preserving separate test processes and environment-controlled seeds. The
runner works outside the development container by selecting Podman or Docker
automatically, and works inside the container with `--direct`. It streams
progress while writing a timestamped campaign directory containing
`manifest.json`, `summary.tsv`, `campaign.log`, and one complete log per
seed/repetition. A nonzero result means at least one case failed; later cases
still run unless `--fail-fast` is supplied. Replay a case by copying its
recorded `AXOLOTY_FUZZ_ITERATIONS`, `AXOLOTY_FUZZ_SEED`, and command from the
case log, after preparing the test products with the same containerized build
command. `make fuzz-long` runs a default 100,000-iteration, four-seed
campaign.

### Integration

Integration tests use a fresh Mosquitto instance or an isolated namespace and
verify Axoloty behavior through public APIs. Cover startup/shutdown, routing,
request/response correlation, lifecycle, reconnect, cancellation, duplicate or
late responses, and broker failure. Readiness must be observed through a health
probe or protocol acknowledgement; fixed sleeps are not readiness checks.

### Wire compatibility

Wire tests treat CoatyJS 2.4.x as the compatibility oracle. The required
interoperability gate uses representative coverage in both directions:

| Direction | Requirement |
|---|---|
| CoatyJS producer -> Axoloty consumer | The offline CoatyJS Advertise fixture is decoded by Axoloty |
| Axoloty producer -> CoatyJS consumer | The live Axoloty Advertise is received and decoded by CoatyJS |

The live Deadvertise, Channel, Discover/Resolve, Query/Retrieve,
Update/Complete, and Call/Return scenarios create both endpoints in CoatyJS.
They are reference-wire protocol coverage for exact topics, correlations,
flags, and semantic payloads; they do not claim Axoloty feature parity or
additional cross-language endpoint coverage.

For each supported communication pattern, tests verify exact MQTT topic,
protocol version, namespace, correlation relationships, QoS and retain flags,
plus semantic JSON. Raw JSON key order, generated UUID values, timestamps, and
client IDs may be normalized only when the scenario proves their relational
meaning. Payload field presence, `null` versus omission, numeric values, array
order, topic levels, QoS, and retain behavior must never be normalized away.

Offline fixtures make PR feedback fast and preserve protocol evidence. Live
tests are authoritative when a fixture and a pinned reference implementation
disagree. Golden data is regenerated only in a dedicated, reviewed change that
states the wire difference and the exact reference version.

## Determinism and isolation

- Pin container images and CoatyJS dependencies. Record the exact versions in
  every live-test artifact bundle.
- Give each scenario a unique MQTT namespace, client IDs, broker network, and
  output directory. Tests must be safe to run concurrently.
- Inject or record clocks, UUIDs, random seeds, and retry schedules.
- Never depend on test execution order or artifacts from an earlier test.
- Poll an observable condition with a deadline instead of sleeping for an
  assumed amount of time.
- Use monotonic time for deadlines. Timeout failures must say what condition
  was awaited and include the relevant logs.
- Avoid public internet access during tests. Reference images and dependencies
  are prepared before execution.

## Timeouts

The tier timeout is a hard upper bound for the complete tier. Individual
network operations should normally use 5 seconds locally and at most 15
seconds on CI. A timeout is a failure, not an automatic retry. Teardown gets a
separate short deadline and must terminate containers even after assertion
failure.

Any timeout increase requires evidence that the expected operation is
legitimately slower. It must not be used to hide missing readiness signals or
races.

## Failure artifacts

Broker-backed and live-wire runs retain an artifact directory on failure. It
must contain, where applicable:

- `manifest.json`: tier, scenario, UTC start time, git revision, reference
  versions, image identifiers, platform, and random seed;
- `capture.jsonl`: lossless MQTT publications including topic, raw payload,
  QoS, retain flag, and ordering;
- `mosquitto.log`, `axoloty.log`, and `coatyjs.log`;
- verifier output and Swift Testing/JUnit output;
- minimized generated input or a replay command.

Successful PR runs may discard bulky captures after verification. Nightly and
release runs retain a compact manifest and summary even on success. Artifacts
must not contain credentials or user data.

## Flake policy

A failing required test blocks the change. CI must not silently retry tests.
One explicit diagnostic rerun may be performed to classify a failure, and both
attempts remain visible. If the rerun passes, the test is flaky rather than
green.

Known flakes require an owner, tracking ticket, captured evidence, and removal
deadline. Quarantine moves a scenario out of the required gate but keeps it
running and reporting; it is never expressed as a skipped assertion in the
main suite. Protocol compatibility tests and repeatable regressions are not
eligible for quarantine. Fix or revert newly introduced flakes before merge.

Nightly repeat runs should randomize scenario order and report pass rate and
seed. The release gate requires no unresolved compatibility flake.

## Manual macOS oracle

Linux/Podman is canonical, but it cannot establish Apple-platform integration.
Before a release candidate, and after changes to TLS, networking, package
platform declarations, or Apple availability code, run on a supported macOS
host:

1. Record macOS, Xcode, Swift, and architecture versions.
2. Resolve the package from a clean checkout and run the full Swift Testing suite.
3. Run the representative Axoloty/CoatyJS Advertise checks in both directions
   against a broker reachable by the Mac, plus the CoatyJS reference-wire
   scenarios for implemented core patterns.
4. Exercise TLS with a test CA and verify rejection of an untrusted endpoint.
5. Attach logs, result bundle, wire captures, and the completed version record
   to the release ticket.

Legacy CoatySwift 2.4.0 may be run as an informational oracle when investigating
a historical discrepancy. Its failure does not override a documented CoatyJS
contract or block Axoloty unless the release explicitly promises that legacy
behavior.

## Adding tests

Place tests at the narrowest tier that proves the behavior. Name test methods
as observable contracts, keep fixtures small, and include a replay path for
generated or live failures. Update `test-tiers.json` when adding a new suite or
changing cadence, timeout, ownership, or artifact policy. Protocol-facing
changes should add an offline regression fixture and, where an Axoloty endpoint
exists, a live CoatyJS interoperability scenario whenever the behavior can
cross the wire. CoatyJS-only scenarios remain useful reference-wire evidence.
