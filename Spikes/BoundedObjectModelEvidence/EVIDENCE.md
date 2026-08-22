<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# G3 bounded object-model evidence

This harness measures the real `AxolotyObjectModel` SwiftPM product. Capacities
`1`, `16`, and `64` are labeled measurement points only; they are not accepted
product presets or public aliases. The probe records `BoundedDynamicObject` and
`ObjectEnvelope` layout size, alignment, and stride with explicit byte/field
versus name/external-ID specializations. Each measurement point runs both
specializations simultaneously; it does not assert that those axes share a
product capacity. The probe also records bounded initialization, deterministic
edit/read operations, exact saturation rejection, and unchanged bytes after
failed edits. Capacity `1` records minimum-object rejection as a measurement
fact; the edit-capacity/no-mutation assertion applies to `16` and `64`.

This revision covers the foundation only. Schema, registry, and predicate
layouts receive separate records after those sources integrate; this report
does not claim they were measured.

Run the hardware-free nodes from the repository root:

```sh
make test-one FILTER='g3-object-model-evidence-host'
make test-one FILTER='g3-object-model-evidence-sanitized'
make test-one FILTER='g3-object-model-evidence-embedded'
```

The host node reuses G1's heaptrack small-vs-large allocation-growth method,
then records the exact `swift --version`, release compile time, binary size,
and section sizes. The
sanitized node runs the same randomized edit/read tests under Address
Sanitizer. Generated reports, logs, and build products are written under
`.testing/g3-object-model/<candidate-sha>/` and are not committed.

The embedded node performs a clean ESP32-C6 cross-build of `Embedded/swift`
through the pinned ESP-IDF toolchain and records the exact Swift version,
compile duration, firmware/ELF/MAP sizes, and ELF section sizes. Its
`coverage` is deliberately `foundation-module-linkage-only`: it proves the
currently integrated foundation is compiled and linked into firmware, not that
future schema, registry, or predicate specializations have been measured.
The node is build-only, hardware-forbidden, and must be rerun after those
sources integrate.

Schema validation is local and dependency-free:

```sh
node Spikes/BoundedObjectModelEvidence/Evidence/validate-evidence.mjs \
  Spikes/BoundedObjectModelEvidence/Evidence/evidence.schema.json REPORT.json
```

Later schema/registry/predicate layouts can add measurement records without
changing the object-model probe's allocation or sanitizer contract.
