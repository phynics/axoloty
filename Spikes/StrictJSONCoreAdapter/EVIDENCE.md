<!-- Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License. -->

# Issue #395 evidence

Command: `./check.sh`

Result (Swift 6.3 Linux container, swift-json `216e30b`):

```text
PASS ASC tokens=8, IOV raw=11..<35
PASS empty: parser at byte 0
PASS invalid-escape: escape at byte 13
PASS invalid-number: number at byte 12
PASS invalid-literal: parser at byte 11
PASS duplicate: duplicate at byte 23
PASS leading-zero: number at byte 12
PASS lone-surrogate: escape at byte 18
PASS depth: depth at byte 46
PASS bad-utf8: utf8 at byte 12
PASS trailing: trailing at byte 13
```

The raw IOV value is the exact borrowed range `11..<35` (the nested object,
including both braces). ASC recognizes all three representative top-level
fields and upstream `_JSONCore` supplies eight structural token ranges.

Embedded objects from the verified run were `_JSONCore` 79,752 bytes, strict
adapter 67,360 bytes, and 146,332 bytes after a partial relocatable link. The
`.swiftmodule` was 332,428 bytes and is build metadata rather than firmware
flash cost. Timing was not recorded because this is a correctness/interface
probe, not a benchmark.

No production source was changed. The adapter core is the same source compiled
for host and Embedded; only the fixture/output harness uses allocations.
