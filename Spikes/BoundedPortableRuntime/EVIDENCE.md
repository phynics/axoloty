<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Bounded portable runtime evidence

This is the maintained G1 probe for issue #629. It is deliberately spike-local:
none of these types are imported by `AxolotyWire`, `AxolotyProtocol`, or a
shipped product.

Run the canonical nodes from the repository root:

```sh
make test-one FILTER='g1-bounded-runtime-host'
make test-one FILTER='g1-bounded-runtime-sanitized'
make test-one FILTER='g1-bounded-runtime-embedded'
```

The host node runs the four capacity specializations (1, 4, 16, 64), records
size/alignment/stride, executes nested mutation and generation-token saturation
checks, runs the parser parity trace, compiles the macro boundary, and measures
release output. The sanitized node repeats the deterministic randomized token
operations under Address Sanitizer. The embedded node uses the pinned
ESP-IDF/Embedded Swift container and a separate `Embedded/` project; it does
not flash a board.

The probe reports storage-event allocation counts. Inline and handler tables
have zero storage events during initialization and warmed operations; the host
parser intentionally owns one reusable contiguous buffer. This is an explicit
probe metric, not a claim about allocator behavior on a physical board.

Run artifacts are written to `.testing/g1-bounded-runtime/<candidate-sha>/` and
are not source-controlled. `Evidence/evidence.schema.json` is the validation
schema for the combined host report.

## Current checkpoint

Host Swift 6.3 compilation and tests pass. The observed inline table layouts
are 12/48/192/768 bytes (size and stride) for capacities 1/4/16/64, with
4-byte alignment; handler layouts are 40/160/640/2560 bytes with 8-byte
alignment. The parser accepts a 512-byte payload in 520 inline bytes and in a
4096-byte host workspace, with identical action traces.

The ESP-IDF 5.4 / Swift 6.3 ESP32-C6 cross-build also passes without flashing:
the firmware image is 137,792 bytes, the ELF is 3,384,080 bytes, and the map
is 2,539,862 bytes. The embedded source instantiates all four capacity
specializations; the report records their measured source-layout growth
(12/48/192/768 inline bytes and 40/160/640/2560 handler bytes). Direct macro
use is rejected by the Embedded Swift consumer, so the checked source uses the
equivalent manual schema conformance. This is a toolchain boundary
observation, not an accepted architecture decision.

The following fields remain `pending-hardware` until two clean ESP32-C6 runs
per candidate configuration exist:

- stack high-water and reserve;
- initialization and warmed steady-state heap;
- flash, data/BSS, and IRAM budgets;
- sustained rate and board revision.

ADR 0004 therefore remains Proposed. No static or host production preset is
selected, and no G2 implementation work is authorized by this spike.
