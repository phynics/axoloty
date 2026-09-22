# Embedded cutover validation

The embedded split ([epic #845]) keeps portable protocol and runtime
implementation in `phynics/axoloty` and concrete firmware composition in
[`phynics/axoloty-embedded`]. This document defines the four validations that
prove the two-repository architecture holds and records which of them ordinary
verification enforces.

## What ordinary verification proves

`Tests/Support/checks/check-embedded-cutover.sh` is a required `ci` gate
(`repository-cutover-boundary`). It needs no firmware checkout, no broker, no
network, and no hardware. It checks four things:

- the published consumer contract (`docs/embedded-consumer-contract.json`)
  names only repository-relative portable Core paths; no absolute path, `..`
  escape, `Tests/`, `.build`, or `Embedded/` path entry survives;
- `AXOLOTY_SOURCE_DIR` is the only local Core override the consumer contract
  documents;
- every required canonical gate declares hardware forbidden and references no
  firmware-owned path, device environment variable, or `.build/embedded`
  directory; and
- the hardware-free `embedded-core-consumer` gate remains in the required plan.

`Tests/Support/selftests/test-check-embedded-cutover.sh` proves every rejection
with synthetic Core and firmware checkouts.

## Test 1 — Axoloty-only developer

Starting from only `git clone phynics/axoloty`:

```sh
make verify
```

The `ci` category runs the host build, portable package tests, module policy,
and the hardware-free `embedded-core-consumer` gate, which compiles the five
portable packages for RISC-V Embedded Swift with a real macro consumer. None
of those needs a firmware checkout, ESP-IDF, a broker, or a device, and the
boundary checker above pins the required plan that way. The firmware-owned
harness self-tests that still run in the required plan execute
in-repository harness scripts and disappear with the removal tracked by #854;
they are not portable Core coverage.

## Test 2 — firmware clean clone

A standalone `axoloty-embedded` clone runs its own entry point:

```sh
Tools/verify.sh --require core
```

That repository fetches the locked Axoloty revision into caller-owned scratch
space through `axoloty-tool embedded consumer prepare`, builds the macro tool
and resolves `_JSONCore` through the published contract, and records both
repository revisions in build provenance. The firmware repository owns that
proof.

From this side, the boundary audit below checks the same lock: it must be
well formed, and every recorded evidence record and release certificate in the
firmware checkout must pin that revision.

## Test 3 — coordinated local development

Sibling checkouts select the local Core without editing lock metadata:

```text
workspace/
├── axoloty/
└── axoloty-embedded/
```

```sh
cd axoloty-embedded
AXOLOTY_SOURCE_DIR=/absolute/path/to/axoloty Tools/prepare-core.sh
```

`AXOLOTY_SOURCE_DIR` is the supported local-development override. The firmware
lock file stays untouched and remains the authority for CI and release builds;
strict mode (`AXOLOTY_STRICT_CORE=1`) rejects a dirty or off-lock local
checkout instead of silently accepting it.

## Test 4 — boundary audit

Run the audit with one firmware checkout:

```sh
AXOLOTY_EMBEDDED_COMPARE_DIR=/absolute/path/to/axoloty-embedded \
  Tests/Support/checks/check-embedded-cutover.sh
```

The audit:

- validates `axoloty-core.lock.json`: schema, `phynics/axoloty` identity,
  `git-commit-sha1` format, and a full 40-character revision;
- runs the firmware repository's own boundary audit
  (`Tools/check-invariants.sh`) with `AXOLOTY_CORE_COMPARE_DIR` set to this
  checkout, so its parent-directory, `.build` scraping, private-reference, and
  copied-source rules compare against real portable Core sources;
- applies the same escaped-layout and copied-source scan directly when the
  firmware checkout predates that audit; and
- requires every `docs/evidence/*.json` record and `releases/*/*.json`
  certificate that names a Core revision to name the locked revision.

Set `AXOLOTY_EXPECTED_CORE_REVISION` to also require a specific locked
revision, for example when validating a release candidate. Without
`AXOLOTY_EMBEDDED_COMPARE_DIR` the audit reports that it skipped, so ordinary
Core verification stays independent of the firmware repository.

## Recorded result

The firmware repository's own audit and this audit agree at its current lock.
At the revision recorded here, `axoloty-embedded` locks Core
`4956298afb4a087147713fce73bb481cf7c59cab` and records:

- the complete ESP32-C6 + MQTT clean-clone build, with a reproducible
  `axoloty-swift.bin` and the contract digest, in
  `docs/evidence/esp32c6-mqtt-firmware-build.json`;
- profile qualification for `esp32c6-mqtt` in
  `releases/esp32c6-mqtt/0.8.2-embedded.2.json`; and
- every tracked evidence record and release certificate pinned to that one
  Core revision.

The audit reported 15 passing boundary invariants and 16 pinned records for
that checkout. Device qualification stays firmware-owned and is not claimed
here.

## Relationship to the remaining removal

`Embedded/`, the firmware-owned harness scripts under `Tests/Support/embedded/`,
and their `Makefile` and `test-tiers.json` families remain in this repository
until the removal tracked by [#854]. The boundary checker already pins the
required plan against new firmware or hardware coupling. When the removal
lands, the remaining `MOVE` paths disappear and the same check proves the
result.

[#854]: https://github.com/phynics/axoloty/issues/854
[epic #845]: https://github.com/phynics/axoloty/issues/845
[`phynics/axoloty-embedded`]: https://github.com/phynics/axoloty-embedded
