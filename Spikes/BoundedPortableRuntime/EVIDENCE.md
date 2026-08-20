<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Bounded portable runtime evidence

This maintained G1 probe resolves issue #629 without promoting spike types into
`AxolotyWire`, `AxolotyProtocol`, or a shipped product. The reviewed decision
candidate is `6a940299`. The physical-device artifact was captured before the
history-only G0 rebase at `0d45c33`; the complete
`Spikes/BoundedPortableRuntime` subtree is byte-identical between those two
commits. After the rebase, the host, sanitizer, and ESP32-C6 cross-build nodes
were rerun successfully at `f9f2d6cf`.

Run the hardware-free nodes from the repository root:

```sh
make test-one FILTER='g1-bounded-runtime-host'
make test-one FILTER='g1-bounded-runtime-sanitized'
make test-one FILTER='g1-bounded-runtime-embedded'
```

With an ESP32-C6 at `AXOLOTY_DEVICE` (default `/dev/ttyACM0`), run:

```sh
make g1-bounded-runtime-device
```

Generated, schema-validated reports and raw logs are written under
`.testing/g1-bounded-runtime/<candidate-sha>/`. Build products and generated
Swift are not committed.

## Reviewed result

The host ran capacities 1, 4, 16, and 64. Heaptrack measured zero allocation-
call growth for inline initialization, warmed inline mutation, handler
registration, and warmed dispatch at every capacity. Address Sanitizer passed
the deterministic randomized-operation and stale-token suite. Exact
saturation, in-place nested mutation, inactive-context rejection, and stale
generation rejection passed. Host inline layouts were 12/48/192/768 bytes;
handler layouts were 32/128/512/2,048 bytes. A 512-byte payload produced the
same action trace in the 520-byte inline workspace and reusable 4,096-byte host
workspace through one generic parser algorithm.

The real host macro consumer compiled with SwiftSyntax 603.0.0. A direct build
of that consumer for `riscv32-none-none-eabi` failed inside SwiftSyntax's
Embedded Swift boundary; the ESP32-C6 project then compiled the equivalent
manual `PortableObjectSchema` conformance from source. No generated Swift is
stored.

The ESP32-C6 cross-build measured each specialization against a no-table
baseline. Firmware growth for capacities 1/4/16/64 was
2,016/2,256/2,496/2,192 bytes; IRAM and BSS growth were zero, and data growth
was 680 bytes. Candidate firmware ranged from 106,608 to 107,088 bytes, below
the existing 1,048,576-byte budget.

Two clean device runs per capacity passed on an ESP32-C6 revision 0 with
4,194,304 bytes of flash. Every run reported:

- zero initialization and warmed steady-state allocations;
- flat internal heap at 415,832 bytes;
- 60,916–62,932 bytes of main-task stack reserve;
- 1,349–1,610 sustained operations per second;
- relative median absolute deviation from 0 to 0.0000873, below the budget
  manifest limit of 0.05.

The report fingerprints the reviewed budget manifest as
`b21d12f2e3c29e5a8ef9b14505ba0a0efe930437268c60e30d4345c118ced1a0`.

## Decision

The evidence satisfies ADR 0004 decision A: literal-inline storage is accepted
without an architecture exception. The measured presets are `tiny = 1`,
`esp32C6Static = 16`, and `hostDefault = 64`. These are G2 inputs, not public
G1 product APIs.
