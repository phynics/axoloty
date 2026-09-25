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

The probe also measures the fixed-inline `ObjectSchemaRegistry` at the same
registry capacities and runs first-party `IoSourceMetadata` typed-object
decoding from `AxolotyProtocol` with an explicit 512-byte arena and field
capacities `1`, `16`, and `64`. Capacity
one exercises registry saturation and typed-object field rejection; capacities
16 and 64 verify successful model decoding and value preservation. These are
measurement points, not product presets. It measures `ObjectPredicate` with
the same 1/16/64 inline specializations; capacity one rejects the canonical
condition, while 16 and 64 perform decode, evaluation, canonical encode, and
round-trip checks.

Run the hardware-free nodes from the repository root:

```sh
make test-one FILTER='g3-object-model-evidence-host'
make test-one FILTER='g3-object-model-evidence-sanitized'
Spikes/BoundedObjectModelEvidence/check-portable.sh
```

The host node reuses G1's heaptrack small-vs-large allocation-growth method,
then records the exact `swift --version`, release compile time, binary size,
and section sizes. The
sanitized node runs the same randomized edit/read tests under Address
Sanitizer. Generated reports, logs, and build products are written under
`.testing/g3-object-model/<candidate-sha>/` and are not committed.

Firmware cross-build evidence is owned by `axoloty-embedded`.
`check-portable.sh` runs the firmware-free portable object-model probe. The
probe is an opt-in script, not a canonical test-tier node. No Core spike reads
the firmware tree or invokes ESP-IDF.

Schema validation is local and dependency-free:

```sh
node Spikes/BoundedObjectModelEvidence/Evidence/validate-evidence.mjs \
  Spikes/BoundedObjectModelEvidence/Evidence/evidence.schema.json REPORT.json
```
