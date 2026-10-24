# Core #1001 review-round evidence

This index records the evidence added for the two round-one review findings.
Full candidate logs remain under
`/tmp/axoloty-batch2-382c4846/core1001-review-fix-evidence/`; paths below are
on the original verification host. The candidate cases are **cached reruns**
performed for this review, not the missing original execution. They use the
candidate from base `0c74f3ae2328a8dc1528088f7b7d3be24f7cf241`, whose
`Package.swift` SHA-256 is
`9b94759cfb5e7cb5dc6fe3abc6602e7dba3057767efde7f6c08532d0433dcaf4`.

## Candidate default and explicit Core builds

The pinned `axoloty-dev` image has manifest digest
`sha256:d87fd69a6d08ae59f733ace17548f6ff6243bef65857c0a3c4f05b6377205c34`
and build-input label
`a5c9e1b623c71ba7316e29fcdfcedfca6109c966b269ebd4dc3713b374577292`.
The compiler is Swift 6.4 (`x86_64-unknown-linux-gnu`). Both builds ran under
`/tmp/axoloty-batch2-382c4846/verification.lock`, using the existing private
SwiftPM cache and separate review-round scratch paths. The per-build command
unsets `PKG_CONFIG_PATH`, `PKG_CONFIG_LIBDIR`, `CPATH`, `C_INCLUDE_PATH`,
`LIBRARY_PATH`, and `LD_LIBRARY_PATH`.

| Case | Expected | Observed |
|---|---|---|
| Candidate root default build | Fail on missing `zenoh.h` in `CAxolotyZenoh` | Exit 1; Clang reports `fatal error: 'zenoh.h' file not found` at `axoloty_zenoh_session.c:9`. |
| Candidate `swift build --product Axoloty` | Pass without native Zenoh | Exit 0; SwiftPM reports `Build complete!`. |
| Native absence before builds | No reachable `zenoh-c` pkg-config/header/library | `pkg-config` cannot resolve `zenohc`; no `zenoh.h` under `/usr/include` or `/usr/local/include`; no `zenohc.pc` or `libzenohc` under `/usr/lib` or `/usr/local/lib`; `ldconfig` has no `libzenohc` entry. The checked environment variables were unset. |

Retained output and SHA-256:

| Artifact | SHA-256 |
|---|---|
| `actual-command.txt` | `8318b0b135be89eb0b32a181e19041a0b715d7723a431d5a72c3bb1763fcfd3c` |
| `rerun-candidate-cases.sh` | `8bb17ff4561ce9142fef056bc6769f3f7cfe1fe7827d95b9166b7f0f80ec57fb` |
| `run-metadata.txt` | `85f93ed6504419681bfdb55a990721e8b8c63d0da482287e5cb024b04a62f357` |
| `compiler-version.txt` | `15174fa03a1cc6d602390777be795e2f5ac630d78e65f677016fac520e243680` |
| `native-absence-and-case-status.stdout` | `f6a8f3ffaec79389a854ad4d959269b8eca43490f9ad7ce12949c75329d1bcc0` |
| `container.stderr` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `candidate-default.stdout` | `634c07d45199aca819fa4547b291563144c92f1cf94635afc786c966f5c30999` |
| `candidate-default.stderr` | `013722ab023c1149cb3825b17b48f54a7f8775eda2183f4d1f121dd61e9c296b` |
| `candidate-default.exit` (contains `1`) | `4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865` |
| `candidate-explicit-core.stdout` | `55c931c94898ef45a9af8705a94f7237f791d8880f7930668269964ab977eb75` |
| `candidate-explicit-core.stderr` | `7f53200065ba63c464808f99cfdbee106e76e17a1096deb3ec4ff1b9c231e67b` |
| `candidate-explicit-core.exit` (contains `0`) | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |

The source checkout was at `8e9f287bce1c0a696abdbd2420226dd3e034a640` for
these reruns. The exact per-case command and scratch paths are in
`actual-command.txt`, `rerun-candidate-cases.sh`, and `run-metadata.txt`.

## Canonical Core verification

The retained canonical run is separate from the candidate rerun. Metadata says
`make verify` at source head `8e9f287bce1c0a696abdbd2420226dd3e034a640`, with
`AXOLOTY_CHECK_CONCURRENCY=1`, image input hash
`a5c9e1b623c71ba7316e29fcdfcedfca6109c966b269ebd4dc3713b374577292`, and
`node-count=66 result=passed`. This evidence applies to that exact source head;
it does not claim a run against the later documentation-only fix commit.

| Artifact | SHA-256 |
|---|---|
| `/tmp/axoloty-batch2-382c4846/core1001-make-verify-metadata-8e9f287b.txt` | `bcf742a92a4ed3d6ffe36c88433decfb839056a2861393e53c695873097825c1` |
| `/tmp/axoloty-batch2-382c4846/core1001-make-verify-scheduler-report-8e9f287b.json` | `3b1770bbc5a884b4d29b14e1330dbfc6ac5950a70b885b14c61ab5daca01e700` |
| `/tmp/axoloty-batch2-382c4846/core1001-make-verify-final-8e9f287b.log` | `acfd5130dd013c759c478b93fda543dbc42ae73c6b1d420b6845e85002ff2e03` |
