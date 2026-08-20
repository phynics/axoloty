---
status: accepted
---

# Use literal-inline bounded runtime state

Protocol and static-runtime state use noncopyable literal-inline storage with
named capacity presets, and the host uses the same bounded algorithms. Storage
saturates atomically and uses slot-index-plus-generation tokens; it does not
hide growable or copy-on-write backing.

[G1 evidence](../../Spikes/BoundedPortableRuntime/EVIDENCE.md) from the rebased
candidate `6a940299` supports decision A. All capacities (1, 4, 16, and 64) compiled on
the pinned host and ESP32-C6 toolchains. Host profiler growth and both device
allocation traces were exactly zero for initialization and warmed operations.
The ESP32-C6 retained at least 60,916 bytes of stack reserve, its heap remained
flat, its firmware stayed below the existing budget, and measured
specialization growth remained bounded. No architecture exception is needed.

The accepted initial presets are:

- `tiny = 1`, the measured exhaustion preset;
- `esp32C6Static = 16`, the measured configuration matching the current
  bounded family-entry limit while retaining substantial resource headroom;
- `hostDefault = 64`, the largest measured configuration, with zero warmed
  allocation growth and small fixed layouts.

These values guide G2's production types. The G1 implementations remain
spike-local and do not themselves add a public Axoloty API. SwiftSyntax macros
work for the host consumer but are unsupported in the current Embedded Swift
consumer; embedded code therefore writes the equivalent source conformance
manually rather than checking in generated Swift. This macro boundary does not
change the literal-inline storage decision.
