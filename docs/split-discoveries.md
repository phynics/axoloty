# Split discoveries

Findings from attempting the Axoloty side of the embedded split (epic #845,
S8 #854, planned by #852). The firmware has already been migrated into
`phynics/axoloty-embedded`. This document records why the matching removal from
`phynics/axoloty` was **withheld** rather than performed, and maps every blocked
path to the retained artifact that still depends on it.

The short version: the per-check inventory in
`phynics/axoloty-embedded/docs/check-inventory.md` classified *embedded* checks
by what they prove. It never mapped the *Core* checks that read the firmware
tree as an input. Those Core checks are retained by the classification rule
("import/module constraints ... stays in Axoloty and must remain hardware-free")
but they physically read `Embedded/swift`, `Tests/Support/embedded`, and the
pre-split resolver scripts. They are the real blockers, and nobody had listed
them.

Consequence: deleting `Embedded/swift/` and the classified `MOVE` /
`SUPERSEDE/DELETE` files breaks `make verify` and Core tooling. Rewriting the
Core gates to assert against the portable packages instead of the firmware tree
is its own change, needs a Swift toolchain, and must not ride along inside a
deletion commit. Until that change lands, the Axoloty-side removal cannot
complete.

## 1. The inventory's blind spot: Core checks that read the firmware tree

None of these checks appears in `check-inventory.md`. By the #852
classification rule they are `KEEP/REWRITE IN AXOLOTY` (import/module
constraints), and all of them are required `ci` gates in
`Tests/Support/test-tiers.json`.

| Core check | `Embedded/swift` input | Required gate id |
|---|---|---|
| `Tests/Support/checks/check-axoloty-object-boundary.sh` | `:16` default component dir; `:95-99` asserts the component's CMake source glob | `g3-object-boundary` |
| `Tests/Support/checks/check-axoloty-object-model-package.sh` | `:16-19`, `:23-24`, `:47-62`, `:96-127`, `:133-136`, `:169-193` assert the ESP-IDF component manifests, globs, and module dependencies | `g3-object-model-package` |
| `Tests/Support/checks/check-axoloty-protocol-package.sh` | `:15` default component path; `:53-70` assert the protocol component's source glob and module ordering | `g2-protocol-package` |
| `Tests/Support/checks/check-g6-architecture.sh` | `:18-24`, `:44-56` assert the wire/protocol component CMake and `cmake/axoloty-source.cmake`; `:92-94` scans `Embedded/` for copied portable source | `g6-architecture-conformance` |
| `Tests/Support/checks/check-g4-runtime-consumer-boundary.sh` | `:15` lists `$root/Embedded/swift/main` as a first-party consumer root | `g4-runtime-consumer-boundary` |
| `Tests/Support/selftests/test-check-g3-object-model-evidence.sh` | `:50` reads `Embedded/swift/components/json_core/CMakeLists.txt`; `:58-66` read `Embedded/swift/main/CoatyModelsModuleConsumer.swift` | `support-object-model-evidence-self-test` |

Their negative self-tests build fixture trees at `Embedded/swift`, so they break
with the tree too:

- `Tests/Support/selftests/test-check-axoloty-object-boundary.sh:15,21,43,50,102`
- `Tests/Support/selftests/test-check-axoloty-object-model-package.sh:20-21,31,45,75,87,100`
- `Tests/Support/selftests/test-check-g6-architecture.sh:14-16,27-28,35,61`

## 2. Firmware evidence ownership

The embedded object-model cross-build evidence producer moves to
`axoloty-embedded`. Core retains the firmware-free host and sanitizer probes,
and keeps the legacy `check-embedded.sh` path as a compatibility wrapper for
the portable probe. No Core spike reads `Embedded/` or invokes ESP-IDF.

## 3. The flagship portability gate depends on `SUPERSEDE` tools

`Tests/Support/checks/check-embedded-swift.sh` contains no `Embedded/` reference,
which is why it was reported safe. It does depend on the pre-split Core
resolvers, both classified `SUPERSEDE/DELETE`:

- `:19,23-24` source `Tests/Support/embedded/prepare-embedded-core-tools.sh`
  and pass `Tests/Support/embedded/resolve-embedded-core.sh`.

Deleting either resolver breaks the required `check-embedded-swift` gate (and
`check-embedded-swift-linker.sh:53,61-62`). They must stay until
`check-embedded-swift.sh` is rewritten to obtain the same values from
`axoloty-tool embedded consumer prepare` (the mechanism the newer
`check-embedded-swift-core.sh` already uses).

## 4. Core tooling call sites

`Tools/AxolotyTooling` is a retained root. It calls, or its tests assert, paths
classified for removal:

| Call site | Referenced path | Disposition |
|---|---|---|
| `Tools/AxolotyTooling/Commands/AxolotyHardwareCommands.swift:42` | `Tests/Support/embedded/embedded-swift-test.sh` | MOVE |
| `Tools/AxolotyToolingTests/Commands/AxolotyCommandDispatcherTests.swift:502,540` | `Tests/Support/embedded/embedded-swift-test.sh` | MOVE |
| `Tools/AxolotyToolingTests/Commands/AxolotyCommandDispatcherTests.swift:456` | `Tests/Support/checks/check-embedded-environment.sh` | SUPERSEDE |
| `Tools/AxolotyToolingTests/Timing/AxolotyTimingTests.swift:179` | `Tests/Support/embedded/build-embedded-swift.sh` | MOVE |
| `Tools/AxolotyToolingTests/Timing/AxolotyTimingTests.swift:187` | `Tests/Support/checks/check-embedded-swift-linker.sh` | MOVE |

`make hardware-check`, `make hardware-require`, and `make checkpoint-hardware`
run through `AxolotyHardwareCommands`, so removing `embedded-swift-test.sh`
without rewriting that command breaks the hardware command family.

## 5. Per-path blocked table

Rule applied: a path is removable only when it has zero inbound references from
a retained artifact (retained checks, selftests, spikes, `test-tiers.json`, the
`Makefile`, and `Tools/AxolotyTooling`). Every path below is blocked. "Candidate
dependents" are other paths in this table; they are retained transitively
because a retained artifact depends on them.

| Path | Disposition | Retained dependents (file:line) |
|---|---|---|
| `Tests/Support/embedded/build-embedded-swift.sh` | MOVE | `Tools/AxolotyToolingTests/Timing/AxolotyTimingTests.swift:179`; `Tests/Support/test-tiers.json:88,97,157` |
| `Tests/Support/embedded/embedded-agent-test.sh` | MOVE | `Makefile:436` |
| `Tests/Support/embedded/embedded-agent-validator.mjs` | MOVE | `embedded-agent-test.sh:63`; `embedded-broker-restart-test.sh:47`; `embedded-coatyjs-test.sh:40`; `embedded-host-test.sh:39`; `embedded-last-will-test.sh:49`; `Tests/Support/selftests/test-embedded-network.sh:60` |
| `Tests/Support/embedded/embedded-broker-restart-test.sh` | MOVE | `Makefile:461` |
| `Tests/Support/embedded/embedded-build-cache.sh` | MOVE | `Spikes/BoundedPortableRuntime/check-embedded.sh:27`; `Tests/Support/checks/check-embedded-swift-linker.sh:52`; `Tests/Support/embedded/build-embedded-swift.sh:44`; `Tests/Support/embedded/embedded-swift-smoke.sh:72`; `Tests/Support/selftests/test-build-embedded-swift.sh:223`; `Tests/Support/selftests/test-esp-idf-ccache.sh:22` |
| `Tests/Support/embedded/embedded-coatyjs-test.sh` | MOVE | `Makefile:442` |
| `Tests/Support/embedded/embedded-corpus-manifest.mjs` | MOVE | `embedded-network-validator.mjs:5`; `embedded-swift-test-validator.mjs:8` |
| `Tests/Support/embedded/embedded-device-info.sh` | MOVE | `Makefile:392` |
| `Tests/Support/embedded/embedded-device-smoke.sh` | SUPERSEDE | `Makefile:397`; `Embedded/main/main.c:8` |
| `Tests/Support/embedded/embedded-host-test.sh` | MOVE | `Makefile:448` |
| `Tests/Support/embedded/embedded-last-will-test.sh` | MOVE | `Makefile:454` |
| `Tests/Support/embedded/embedded-mqtt-host-hal.c` | MOVE | `embedded-mqtt-host-test.sh:14` |
| `Tests/Support/embedded/embedded-mqtt-host-test.sh` | MOVE | `Tests/Support/selftests/test-embedded-mqtt-client.sh:65` |
| `Tests/Support/embedded/embedded-mqtt-host-test.swift` | MOVE | `embedded-mqtt-host-test.sh:21` |
| `Tests/Support/embedded/embedded-network-test.sh` | MOVE | `Makefile:430` |
| `Tests/Support/embedded/embedded-network-validator.mjs` | MOVE | `embedded-network-test.sh:23`; `Tests/Support/selftests/test-embedded-mqtt-client.sh:21-25`; `Tests/Support/selftests/test-embedded-network.sh:59` |
| `Tests/Support/embedded/embedded-reproducible-build.sh` | SUPERSEDE | `Makefile:402` |
| `Tests/Support/embedded/embedded-runtime-identity-test.c` | MOVE | `Tests/Support/selftests/test-embedded-runtime-identity.sh:17` |
| `Tests/Support/embedded/embedded-shared-flags-test.c` | MOVE | `Tests/Support/selftests/test-embedded-mqtt-client.sh:48` |
| `Tests/Support/embedded/embedded-swift-reproducible-build.sh` | MOVE | `Makefile:479`; `Tests/Support/selftests/test-build-embedded-swift.sh:350,364` |
| `Tests/Support/embedded/embedded-swift-smoke-validator.mjs` | MOVE | `embedded-swift-smoke.sh:121`; `embedded-swift-test-validator.mjs:7`; `embedded-network-validator.mjs:3`; `Tests/Support/selftests/test-embedded-swift-smoke.sh:65,88,185,193`; `Tests/Support/selftests/test-embedded-swift-test.sh:9` |
| `Tests/Support/embedded/embedded-swift-smoke.sh` | MOVE | `Makefile:412`; `embedded-network-test.sh:25`; `embedded-swift-test.sh:9`; `Tests/Support/selftests/test-embedded-swift-smoke.sh:153`; `Tests/Support/test-tiers.json:86,162` |
| `Tests/Support/embedded/embedded-swift-test-validator.mjs` | MOVE | `Makefile:419`; `embedded-swift-test.sh:7`; `embedded-network-validator.mjs:4`; `Tests/Support/selftests/test-embedded-swift-test.sh:10` |
| `Tests/Support/embedded/embedded-swift-test.sh` | MOVE | `Makefile:421`; `Tests/Support/test-tiers.json:90,100,163`; `Tools/AxolotyTooling/Commands/AxolotyHardwareCommands.swift:42`; `Tools/AxolotyToolingTests/Commands/AxolotyCommandDispatcherTests.swift:502,540` |
| `Tests/Support/embedded/generate-embedded-network-config.mjs` | MOVE | `embedded-agent-test.sh:37`; `embedded-broker-restart-test.sh:37`; `embedded-coatyjs-test.sh:31`; `embedded-host-test.sh:35`; `embedded-last-will-test.sh:34`; `embedded-network-test.sh:19`; `Tests/Support/selftests/test-embedded-network.sh:10,50` |
| `Tests/Support/embedded/resolve-embedded-core.sh` | SUPERSEDE | `Tests/Support/checks/check-embedded-swift.sh:24`; `check-embedded-swift-linker.sh:53,62`; `build-embedded-swift.sh:20`; `prepare-embedded-core-tools.sh:124`; device harnesses |
| `Tests/Support/embedded/prepare-embedded-core-tools.sh` | SUPERSEDE | `Tests/Support/checks/check-embedded-swift.sh:23`; `check-embedded-swift-linker.sh:61`; `build-embedded-swift.sh:19`; device harnesses |
| `Tests/Support/checks/check-embedded-swift-linker.sh` | MOVE | `Tools/AxolotyToolingTests/Timing/AxolotyTimingTests.swift:187`; `Tests/Support/test-tiers.json:80,98,160` |
| `Tests/Support/checks/check-embedded-environment.sh` | SUPERSEDE | `Tests/Support/test-tiers.json:95`; `Tools/AxolotyToolingTests/Commands/AxolotyCommandDispatcherTests.swift:456` |
| `Tests/Support/checks/check-embedded-toolchain.sh` | MOVE | only a comment reference at `Tests/Support/embedded/embedded-device-info.sh:93`; the tooling's `embedded doctor` resolves to `check-embedded-environment.sh`, so this path is already orphaned in tooling |
| `Tests/Support/checks/check-benchmark-wire-device.sh` | MOVE | `Makefile:619`; `Tests/Support/selftests/test-check-benchmark-wire-device.sh:24`; `Tests/Support/test-tiers.json:87,155`; `Embedded/benchmark/main/benchmark_main.c:12` |
| `Tests/Support/lib/serial-tools.mjs` | MOVE | `Tests/Support/selftests/serial-tools.test.mjs:7`; `Spikes/BoundedPortableRuntime/Evidence/capture-device.mjs:4`; device harnesses |
| `Tests/Support/selftests/test-build-embedded-swift.sh` | MOVE | `Tests/Support/test-tiers.json:88,157` |
| `Tests/Support/selftests/test-check-embedded-swift-linker.sh` | MOVE | `Tests/Support/test-tiers.json:80,160` |
| `Tests/Support/selftests/test-embedded-coatyjs.sh` | MOVE | `Tests/Support/test-tiers.json:93,167` |
| `Tests/Support/selftests/test-embedded-mqtt-client.sh` | MOVE | `Tests/Support/test-tiers.json:92,166` |
| `Tests/Support/selftests/test-embedded-network.sh` | MOVE | `Tests/Support/test-tiers.json:91,165` |
| `Tests/Support/selftests/test-embedded-runtime-identity.sh` | MOVE | `Tests/Support/test-tiers.json:81,164` |
| `Tests/Support/selftests/test-embedded-swift-smoke.sh` | MOVE | `Tests/Support/test-tiers.json:86,162` |
| `Tests/Support/selftests/test-embedded-swift-test.sh` | MOVE | `Tests/Support/test-tiers.json:90,163` |
| `Tests/Support/selftests/test-check-benchmark-wire-device.sh` | MOVE | `Tests/Support/test-tiers.json:87,155` |

The `check-embedded-toolchain.sh` row is the only near-miss: it has no
functional inbound reference in this repository. It was still left in place,
because the `Makefile` help text and the inventory describe it as the
`embedded doctor` script, the `embedded-device-info.sh` comment names it, and
deciding its fate belongs with the Core-gate rewrite described in section 8.

## 6. The one safely removable path

`Tests/Support/embedded/generate-embedded-corpus.mjs` has zero inbound
references to its path from any retained artifact:

```sh
grep -rn --exclude-dir=.git -F 'generate-embedded-corpus.mjs' .
```

returns only the two orphan copies' own usage strings
(`Tests/Support/embedded/generate-embedded-corpus.mjs:8`,
`Embedded/swift/fixtures/generate-embedded-corpus.mjs:8`) and the firmware's own
CMake reference (`Embedded/swift/main/CMakeLists.txt:25`), which resolves
`AXOLOTY_CORPUS_FIXTURE_DIR` to `Embedded/swift/fixtures` (`:24`), not to
`Tests/Support`. The migrated generator lives in
`axoloty-embedded` at `Applications/device-smoke-agent/fixtures/`. The file was
removed in the removal commit.

## 7. Left alone, and why

- `Embedded/main/` — the older C smoke firmware. Its checks are `SUPERSEDE`, but
  the inventory does not clearly disposition the application tree itself; it is
  left untouched and listed here as unclassified.
- `Embedded/benchmark/` — classified `MOVE`, but unmigrated (note B). Deleting
  it now would destroy the only copy of firmware that never moved. Left alone.
- `docs/embedded-toolchain.md` — classified `MOVE`, but still linked from
  `README.md:188`, `Makefile:386`, and the `Embedded/` CMake files. It stays
  until the firmware-tree removal and the wording tense-flip happen together.

## 8. What must happen before the Axoloty-side removal can complete

1. Rewrite the Core gates in section 1 and the self-tests they rely on so they
   assert against the portable packages and the `axoloty-tool embedded consumer
   prepare` report, not the firmware tree. This changes required CI coverage and
   needs a Swift toolchain to verify.
2. Replace the firmware implementation behind
   `Spikes/BoundedObjectModelEvidence/check-embedded.sh` with the firmware-free
   compatibility probe and remove the `Embedded/swift` constant from its schema
   and `EVIDENCE.md`.
3. Rewrite `check-embedded-swift.sh` to stop sourcing
   `prepare-embedded-core-tools.sh` and `resolve-embedded-core.sh`, so those
   `SUPERSEDE` files can go.
4. Rewrite `AxolotyHardwareCommands` and its tests for the hardware-command
   family, and delete the `AxolotyTimingTests`/`AxolotyCommandDispatcherTests`
   assertions for the removed paths.
5. Only then delete `Embedded/swift/`, the `MOVE`/`SUPERSEDE` files above, the
   `embedded-swift-*`, device, broker, interop, and consumer-proof `Makefile`
   families, and their `Tests/Support/test-tiers.json` nodes — under the same
   gated commit the task requires: not before `axoloty-embedded` proves a
   clean-clone build of the ESP32-C6 + MQTT profile against the locked Core
   revision.

## 9. Update 2026-09-19: the build precondition is met, and so is the toolchain

Two of the assumptions section 8 was written under have since changed.

**The clean-clone precondition in item 5 is satisfied.** `axoloty-embedded`
built the ESP32-C6 + MQTT profile from a standalone clone against this exact
locked revision, `39e1ec0662f65f853c7439ca7d636fd579cc4c05`, with
`AXOLOTY_STRICT_CORE=1` and Core reporting `dirty=false`:

| | |
|---|---|
| artifact | `axoloty-swift.bin`, 749456 bytes |
| SHA-256 | `7a2780258888c8bd52034d3de6397de38a958cbc09ad6f693c605519d743a8e3` |
| contract | `72a48bdc9beabca6583ff55fdffe4ba3a05266dbd8d475bd36e8b21cafa56933` |
| toolchain | `axoloty-dev:latest` — Swift 6.3.3, ESP-IDF v5.4 |

The digest was reproduced by a second run from an independent scratch tree.
The record is `docs/evidence/esp32c6-mqtt-firmware-build.json` in that
repository, at build tier. Note the tier: **the profile is still unqualified**,
because no board has been flashed. Item 5's gate was written about the build,
and the build is now proven; do not read this as device qualification.

**Item 1's "needs a Swift toolchain to verify" is no longer a blocker.** The
toolchain is in a container, not on PATH — `docker images` shows
`axoloty-dev:latest` and `swift:6.3-jammy`. A gate rewrite can therefore be
verified here rather than deferred.

So the remaining blockers are items 1–4 — all of them rewrites of Core-side
checks that read `Embedded/swift`, none of them waiting on anything external.
Item 5 stays last, and stays a single gated commit.
