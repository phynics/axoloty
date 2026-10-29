# Core 1.0 pre-release readiness evidence

This record binds the retained release checkpoint to Core commit
`d69b9aa8e0b56532483663688f65db287ffb0d27`, tree
`1b1199b2b5a0338fcd194eb07bdcd783acf2989a`, version `0.9.0`, on Linux with
Swift 6.4. It is technical evidence for owner review. It is not a 1.0 release
certificate or owner approval.

The checkpoint ran on 2026-10-26 with `make checkpoint`. Its raw JSON report
records 71 passing results and exit code 0. The release gate dispositions are:

| Gate | Checkpoint disposition | Evidence meaning |
| --- | --- | --- |
| `ci` | Executed | 66 nodes passed on the exact checkpoint subject. |
| `wire` | Covered by CI | Reuses the full CoatyJS capture at `d9743489…`; no stable product source changed from that commit to this candidate. The candidate workflow run is a fast path and made no capture. |
| `wire-cbor` | Executed | Golden corpus and host/static trace parity passed on the checkpoint subject. |
| `embedded` | Executed | Hardware-free Core Embedded Swift consumer passed. This is not firmware or device qualification. |
| `zenoh-live` | Covered by CI | The checkpoint did not run a new live Zenoh test. Zenoh remains experimental. |
| `zenoh-offline` | Executed | Both offline package and Embedded Swift core checks passed. |
| `swiftpm-sbom` | Executed; artifact recovered | The checkpoint's CycloneDX JSON was recovered from its original checkpoint worktree and copied into the supplemental evidence bundle. Its SHA-256 is `97b689d7ac26fbab61153691a55296959e2e87c8fdd606d858a5fc67871a9fc8`, matching the checkpoint report. The checkpoint ran `AxolotySwiftPMSBOMValidator` against that file and the exact `Package.resolved`; the retained report records `SwiftPM CycloneDX SBOM matches Package.resolved`. The final bundle rechecks the file digest and each of its 11 external package components against the lockfile. This does not certify that every lock pin appears in the generated SBOM. |

The checkpoint ran the public consumer twice. Both receipts requested the
canonical GitHub repository at exact revision
`d69b9aa8e0b56532483663688f65db287ffb0d27` with local mode disabled. The
retained debug and release build and run logs include Core, Wire, Portable,
MQTT, and TransportSPI consumer runs. Their product-specific markers are
required by the final evidence checker. The TransportSPI runs also include the
public diagnostic behavior marker. The copied evidence is under the Sol final
evidence bundle referenced in the handoff response. The fresh consumer has its
own resolved dependency lock. Six transitive versions differ from the root
checkpoint lock; both inventories and their separate hashes are retained.

The full live MQTT/Coaty capture is from successful GitHub run 39970052199,
whose PR head is `d9743489de9b47f9792856f5adea0f1653b06c02`. The workflow
receipt separately records the GitHub merge ref
`77b7390a13594523c70a82f48099913933df690d`; it is not the PR head or d69.
The hosted checkout log confirms execution at that merge ref. Its entire source
tree equals the PR head tree `193ce557f567b8e12a1037848001c640eece1f9b`, as
checked from the retained GitHub commit/tree records. It has verified captures
for Axoloty and CoatyJS 2.4.0 scenarios. GitHub run 40099948519 is a
successful fast-path run at `6e9997ebfd842eb46f87e0246a2909d62e46d037`; its
receipt says capture and verification were not attempted. The release
checkpoint correctly labels `wire` as covered by CI. Do not describe the
fast-path run as a new live capture.

The reviewed API check at `e6e6eda6dbe6005308f4cac730294110573cdded` found
zero delta against the approved 27-file public-symbol baseline. The baseline
file at this checkpoint is byte-identical to the file at that reviewed commit.
No `Source`, `Packages`, `Package.swift`, or `docs/api` path changed between
the reviewed API commit and this checkpoint. The API result is therefore
reusable for this candidate; it is not a new candidate-specific compiler run.

The claim audit corrected iOS classification errors in `README.md`,
`docs/testing.md`, and this readiness document. The authoritative contract
in `docs/SUPPORT_MATRIX.md` and issue #998 is Linux validated, macOS best
effort, and iOS experimental and unvalidated. `VERSION` remains `0.9.0`, the
1.0 notes remain unreleased, and Zenoh remains experimental and outside the
root package. No host diagnostic result is presented as embedded hardware
evidence. These documentation edits are a source delta from checkpoint d69;
they do not change the checkpoint subject or relabel its evidence. The final
bundle records exact changed paths, hashes, and the documentation tree
separately from the checkpoint.

The recovered SBOM reports 11 external package components from the 15-pin
lockfile. `swift-asn1`, `swift-docc-plugin`, `swift-docc-symbolkit`, and
`swift-system` do not appear as external package components. The production
validator checks reported external GitHub Swift packages against their pins;
it does not require every lock pin to appear. The final checker binds the
original bytes, root subject, reported component set, and every reported
package's location, version, and revision. The lockfile remains unchanged.

Successful Zenoh CI run [40099948766](https://github.com/phynics/axoloty/actions/runs/40099948766)
at `6e9997ebfd842eb46f87e0246a2909d62e46d037` retains live router and peer
results. Its package/runtime sources and lockfile match d69. This is reused
experimental evidence, not a new d69 live execution or Zenoh graduation.

## Packet replay

Retain the supplemental Sol final evidence bundle with the handoff response.
Run `python3 -B <bundle>/verify_evidence.py --repo <checkout>` in a checkout
with the recorded Git history. The checker validates the exact base-to-docs
delta from d69 in the index and the working files. It accepts the intended
staged state and the same tree after a normal documentation commit. It rejects
unrelated tracked changes and untracked files. The bundle is an audit packet,
not a production exact-subject attestation or a new candidate certificate.

## Owner decision

`ownerSignoff=PENDING`. Proposed owner decision for review after the final
review and implementation self-verification of its fixes:

> I accept the completed technical evidence for Core issue #1043 against the
> exact software checkpoint subject `d69b9aa8e0b56532483663688f65db287ffb0d27`
> (tree `1b1199b2b5a0338fcd194eb07bdcd783acf2989a`, version `0.9.0`) and the
> separately identified documentation correction delta in this packet. I
> approve the technical acceptance criteria for #1043 and authorize its
> completion on that evidence. This acceptance reuses the identified live
> MQTT/Coaty capture and reviewed API comparison, and accepts their stated
> subjects and limits. I accept the recovered SBOM's stated scope of 11
> reported external packages from 15 lock pins. Platform scope remains Linux
> validated, macOS best
> effort, and iOS experimental and unvalidated. This decision does not
> authorize a version change, tag, package publication, GitHub Release, new
> support claim, Zenoh graduation, or hardware qualification claim.

This is proposed language, not a recorded approval. `ownerSignoff` remains
`PENDING`; the parent owns the final owner decision and issue action.
