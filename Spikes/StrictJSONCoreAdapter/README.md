<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Strict `_JSONCore` adapter spike (#395)

This is intentionally isolated from `Source/` and `Packages/AxolotyWire`. Run
`./check.sh` from this directory. The script clones swift-json revision
`216e30b` and creates a temporary package exposing its public `_JSONCore`
target; this is probe mechanics only. Issue #394 owns production dependency
placement (including the Swift 6.2.3 manifest product seam).

`StrictJSONCoreAdapter.swift` is the reusable adapter core. It has no
Foundation, `String`, `Array`, `Set`, dictionary, or tree; recognized fields are
fixed optional ranges plus a bitset. `_JSONCore` is the sole structural parser:
the destination tracks root key/value state and nesting through token callbacks
and derives primitive/container raw ranges from callback contexts. A bounded,
non-recursive lexical pass only validates quoted-string UTF-8/control/escape
syntax and surrogate pairs, and rejects nesting deeper than eight before the
upstream traversal. Number ranges are checked in the destination. Callback
failures are captured and thrown after scanning.

Evidence: the executable prints deterministic reason/byte-offset diagnostics
for duplicate, leading-zero, lone-surrogate, depth, and invalid-UTF-8 cases,
and verifies valid ASC plus exact IOV raw range. `check.sh` runs the host
harness and the direct corrected-#392-style Embedded probe with target
`riscv32-none-none-eabi`, Embedded/Lifetimes/StrictConcurrency, package name
`IkigaJSON`, module name `_JSONCore`, and a consumer compile using `-I`.
