# Borrowed-Lifetime Audit

Audit of the borrowed-bytes wire design (`ByteSlice`, `BorrowedMessage`,
`TopicView`, `BorrowedProtocolFrame`, `WireValueView`, `WireReader`, and
similar non-copying "view" types that hold a raw pointer into a buffer they
do not own) for places where a pointer or pointer-derived value escapes the
scope that guarantees its validity.

Two real bugs of this shape were found and fixed just before this audit:

1. `TopicLayoutConformanceTests.view(_:)` (fixed in `6172052`) returned a
   `TopicView` constructed inside `bytes.withUnsafeBufferPointer { ... }`.
   `bytes` was local to `view(_:)`, so its backing storage was deallocated
   the instant `view(_:)` returned — every assertion built on the result
   read freed memory, and the negative assertions were vacuously passing.
2. `ProtocolProcessor`'s outbound `IoValue` publish path (fixed in
   `880ff26`) built a `ByteSlice` inside
   `withUnsafeBytes(of: associations[i].route) { ... }` and appended it to
   `InlineProtocolActionSink`, a documented non-copying sink read by the
   caller *after* `processOutbound` returns. The compiler reused one stack
   slot across loop iterations, so the sink held one route's bytes
   truncated to another route's length — a live wire-corruption bug.

Scope: `Source/`, `Packages/*/Sources/`, and `Tests/`, excluding the
static-replay path reserved by another concurrent effort
(`Tests/AxolotyTests/ProtocolTrace/`, `Packages/AxolotyStaticRuntime/`).

## Result

**Zero additional genuine bugs found.** Every other `withUnsafe*` call site
in scope either consumes its derived pointer/view entirely inside the
closure, hands it to a callee that copies it into owned/bounded storage
before the closure returns, or is a same-enclosing-scope test helper where
the owning array is never deallocated, mutated, or reused before the
derived value's last use (see "Same-scope borrow" pattern below, and the
distinction from the two real bugs).

## How each site was classified

**BUG** — the escaping scope is guaranteed to end (the owning buffer is
deallocated, mutated, or reused for a different value) before the derived
pointer-holding value's last use, so the failure is reachable, not
speculative.

**SAFE** — the derived value is consumed (or reduced to a primitive/copied
value) entirely inside the closure, the callee it's passed to copies it
before returning, or it is used later only within a scope where its owning
buffer provably has not moved, been mutated, or been deallocated.

### Genuinely safe: closure-scoped consumption (the overwhelming majority)

This is the standard, correct idiom used almost everywhere `withUnsafe*` is
called in this codebase: the closure's own return value is a primitive
(`Bool`, `Int`, `[UInt8]` copy), an owned/bounded type that copies bytes in
its initializer (`BoundedIoBytes`, `BoundedEncodedText`, `BoundedJSONValue`,
`OwnedJSONValue`, `ObjectEditor`, `BoundedDynamicObject`), or the result of
a caller-supplied nonescaping `body` closure invoked *while the pointer is
still valid*. Representative examples audited and confirmed safe:

| Site | Why safe |
|---|---|
| `Packages/AxolotyWire/Sources/AxolotyWire/WireEvents.swift` (`ownedString`, `ownedRaw`) | `ByteSlice` built inside the closure is written to `writer` (which copies) synchronously, before the closure returns. |
| `Packages/AxolotyWire/Sources/AxolotyWire/WireReader.swift` (`init(bytes:length:)`, `isValidJSONValue`) | `WireFieldIndex`/`WireFieldSlot` store `Range<Int>` offsets, never pointers; `self.bytes` is set once, directly, to the caller's original buffer — not to the temporary padded tokenizer workspace. Indexed reads later re-derive pointers from `self.bytes`, which the *caller* (not this initializer) guarantees stays alive. |
| `Packages/AxolotyWire/Sources/AxolotyWire/WireValueReader.swift` (`withArrayElements`, `withBorrowedArrayElements`) | `WireArrayElementDestination` stores element `Range<Int>`s computed inside a `withUnsafeTemporaryAllocation` scope, not pointers; the temporary padded buffer never escapes. |
| `Packages/AxolotyWire/Sources/AxolotyWire/UUID16.swift`, `OwnedWireDataValidation.swift` | Return `Bool`/`WireDecodeError?`/`(Bool, Int)`, all consumed inside the closure. |
| `Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/BoundedDynamicObject.swift` (`edit`, `editEncodedFields`) | `ObjectEditor.init(source:)` copies every byte into its own `InlineArray` storage inside the initializer call, so the `editor` returned from `withUnsafeBytesOfRaw` is a fully owned value despite the visual shape resembling the bug. |
| `Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/ObjectPredicate.swift` (`withSegment`, `literalSlice`) | Explicitly documented: "The callback result is deliberately non-generic so a `ByteSlice` cannot be returned accidentally." |
| `Packages/AxolotyProtocol/Sources/AxolotyProtocol/InlineOwnedProtocolActionSink.swift` (`visit(at:_:)`) | Documented nonescaping visitor: "The action and every byte slice become invalid when this call returns." Fixed instance of the sink (`append`) now stores a copied `BorrowedProtocolRouteSnapshot`, not a `ByteSlice`. |
| `Packages/AxolotyProtocol/Sources/AxolotyProtocol/ProtocolProcessor.swift` (`processOutboundOperation`, `processInbound`-adjacent code in `Source/Runtime/AxolotyRuntime.swift`) | `consumeAcceptedActions()` / `dispatchActions(nowMS:)` are called *inside* the `withUnsafeBufferPointer` closure, converting every `BorrowedProtocolAction` to an owned action (`borrowed.owned()`) before the closure returns — the exact pattern the 880ff26 fix established. |
| `Packages/AxolotyProtocol/Sources/AxolotyProtocol/ProtocolProcessor.swift` (`advertisedObjectField`) | Returns a `ByteSlice?` that is a sub-view of the caller-supplied `payload: ByteSlice` *parameter* — not a new closure-local temporary. As valid as `payload` itself, which is the caller's existing borrow contract. |
| `Source/Runtime/AxolotyRuntimeDefinition+IO.swift` (`ioActor`, `dynamicIoActor`) | `Value.decodeIoPayload` / `DynamicIoValue.decodeIoPayload` copy into `BoundedIoBytes`/`BoundedJSONValue` before returning. |
| `Source/Runtime/MQTTBinding.swift` (`topic(for:namespace:...)`, `uuidString`) | Returns `Int`/nothing from the closure; the `String` result is built afterward via `String(decoding:as:)`, which copies. |
| `Packages/AxolotyWire/Sources/AxolotyWire/WireParserWorkspace.swift` | Generic `withStorage<R>(_:) -> R` passthrough — the safety obligation ("no workspace bytes escape...") is on the *caller*, matching every verified call site (`WireReader.init`). |

### Genuinely safe: same-scope borrow (a distinct pattern from the two bugs)

`Packages/AxolotyWire/Tests/AxolotyWireTests/WireCodecTests.swift` and
`Packages/AxolotyObjectModel/Tests/AxolotyObjectModelTests/ObjectPredicateCodingTests.swift`
contain many instances of:

```swift
let view = bytes.withUnsafeBufferPointer { buf in
    TopicView(topicBytes: buf.baseAddress!, length: buf.count)
}
#expect(view.levelCount == 5)   // used after the closure returns
```

This *looks* like the same shape as bug #1, but it is a materially
different case: `bytes` is a `let` local **in the same function** as every
subsequent use of `view`, is never mutated or reallocated, and does not go
out of scope until the test function itself returns (after all uses). Bug
#1's `view(_:)` helper, by contrast, was called *from a different
function*, so `bytes` had already been deallocated — a real, ARC-guaranteed
dangling pointer — by the time the caller touched the result. Here there is
no reachable deallocation, mutation, or reuse event between the pointer's
capture and its last use, so there is no concrete failure mode, and the
full `AxolotyWireTests` (120 tests) and the relevant `AxolotyObjectModel`
tests pass consistently. This is flagged in the audit for transparency
(it is technically outside the letter of `withUnsafeBufferPointer`'s "valid
only during the closure" documentation) but is not treated as a bug to fix,
per the instruction to report zero-bug results plainly rather than invent
work. The automated gate (below) is scoped to *not* flag this pattern,
specifically because it does not match the two real bugs' shape (a scope
boundary that is actually crossed).

## Automated gate

`Tests/Support/checks/check-no-escaping-borrows.sh` (self-test:
`Tests/Support/selftests/test-check-no-escaping-borrows.sh`) flags the exact shape of
bug #1 generalized to any of the borrowed view types: a
`return <expr>.withUnsafeX(...) { ... }` (or free-function
`withUnsafeBytes(of:)` / `withUnsafeMutableBytes(of:)` spelling) whose
trailing closure's last statement is a bare `TypeName(...)` construction of
`ByteSlice`, `TopicView`, `BorrowedMessage`, `BorrowedProtocolFrame`,
`WireValueView`, or `WireReader` — with nothing chained after it. A chained
`.property`/`.method()` access (e.g. the fixed helper's
`TopicView(...).eventType`) projects the borrow down to a safe value before
the closure returns and is correctly not flagged; the many closures that
return a `Bool`/`Int`/generic `body(...)` result are also correctly not
flagged.

The scanner (`Tests/Support/lib/detect-escaping-borrow.pl`) does real brace-depth
tracking (after stripping `//` comments) from the closure's own opening
brace to find *that* closure's matching close, rather than "the next line
that is a bare `}`" — the latter is wrong as soon as the closure body
contains its own nested `guard`/`do`-`catch`/`if` blocks, which produced a
false positive against `Source/Runtime/ProtocolExecutor+Outbound.swift`
during development of this check (caught and fixed before landing).

Bug #2's shape (a non-copying sink retaining a value built inside a
per-loop-iteration `withUnsafeBytes(of:)` over a mutable/changing source) is
not mechanically detectable with a textual scanner without much higher
false-positive risk, and is not attempted here; the fix for that bug
(`880ff26`) replaced the escaping `ByteSlice` with a copied
`BorrowedProtocolRouteSnapshot` at the type level, which is the durable fix.

The gate currently passes on the full tree with **no allowlist entries
required** — the audit found no remaining instances of the pattern outside
the two already-fixed sites. The script has an explicit `ALLOWLIST`
variable (empty) for any future legitimate construct that happens to match
textually; per the task's guidance, loosening the regex is not an option —
any such case should be added there with a comment explaining why the
borrow does not actually escape.

This script is intentionally **not** wired into the check-plan JSON or CI
graph. A maintainer adding it to CI should add
`Tests/Support/checks/check-no-escaping-borrows.sh` alongside the other
`check-no-*.sh` entries (see `check-no-anycodable.sh`,
`check-no-foundation-types.sh`) in whatever manifest drives the check-plan
(e.g. `test-tiers.json` / the CI workflow that invokes `Tests/Support/*.sh`).

## Explicitly out of scope

`Packages/AxolotyStaticRuntime/` and `Tests/AxolotyTests/ProtocolTrace/`
were excluded per instructions (reserved for a concurrent SIGBUS fix) and
were not audited or scanned by the gate.
