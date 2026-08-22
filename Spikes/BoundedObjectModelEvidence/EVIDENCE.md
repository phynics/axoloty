<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# G3 bounded object-model evidence

This harness measures the real `AxolotyObjectModel` SwiftPM product. Capacities
`1`, `16`, and `64` are labeled measurement points only; they are not accepted
product presets or public aliases. The probe records `BoundedDynamicObject` and
`ObjectEnvelope` layout size, alignment, and stride, bounded initialization,
deterministic edit/read operations, exact saturation rejection, and unchanged
bytes after failed edits. Capacity `1` records minimum-object rejection as a
measurement fact; the edit-capacity/no-mutation assertion applies to `16` and
`64`.

Run the hardware-free nodes from the repository root:

```sh
make test-one FILTER='g3-object-model-evidence-host'
make test-one FILTER='g3-object-model-evidence-sanitized'
```

The host node reuses G1's heaptrack small-vs-large allocation-growth method,
then records release compile time, binary size, and section sizes. The
sanitized node runs the same randomized edit/read tests under Address
Sanitizer. Generated reports, logs, and build products are written under
`.testing/g3-object-model/<candidate-sha>/` and are not committed.

Schema validation is local and dependency-free:

```sh
node Spikes/BoundedObjectModelEvidence/Evidence/validate-evidence.mjs \
  Spikes/BoundedObjectModelEvidence/Evidence/evidence.schema.json REPORT.json
```

Later schema/registry/predicate layouts can add measurement records without
changing the object-model probe's allocation or sanitizer contract.
