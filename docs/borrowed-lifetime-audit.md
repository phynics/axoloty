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
| `Packages/AxolotyMQTT/Sources/AxolotyMQTT/MQTTBinding.swift` (`topic(for:namespace:...)`, `uuidString`) | Returns `Int`/nothing from the closure; the `String` result is built afterward via `String(decoding:as:)`, which copies. |
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

## Swift 6.4 `~Escapable` + `RawSpan` spike (#872)

Question: should the borrowed wire views (`ByteSlice`, `TopicView`,
`WireValueReader`) store a `RawSpan` and become `~Escapable`, so the rule
above ("borrowed values stay inside synchronous calls") is enforced by the
compiler instead of by convention and review?

A prototype was compiled with the pinned `swift:6.4-jammy` toolchain for both
the host and `riscv32-none-none-eabi` Embedded. The viable shape is:

```swift
public struct SpanSlice: ~Escapable {
    @usableFromInline let raw: RawSpan

    @_lifetime(borrow raw)
    @usableFromInline init(borrowing raw: RawSpan) { self.raw = raw }

    public var length: Int { raw.byteCount }

    public func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < raw.byteCount else { return nil }
        return raw[index]
    }

    @_lifetime(copy self)
    public consuming func subSlice(from start: Int, length len: Int) -> SpanSlice {
        let lower = Swift.max(0, start)
        let end = Swift.min(start + len, raw.byteCount)
        return SpanSlice(borrowing: raw.extracting(lower..<end))
    }
}
```

Findings:

- The shape works. With `-enable-experimental-feature Lifetimes`, the struct,
  the `@_lifetime` annotations, safe construction from `Array.span.bytes`, a
  localized `@unsafe RawSpan(_unsafeBytes:)` pointer bridge, a static `empty`
  sentinel, noncopyable `Equatable`/`Hashable`, and passing into an `async`
  function all compile. They also compile for Embedded riscv32.
- The feature is still experimental in 6.4. Without the flag the host build
  fails with `'@_lifetime' attribute is only valid when experimental feature
  Lifetimes is enabled`. Only
  `Tests/Support/checks/check-embedded-swift-core.sh` passes the flag today;
  no host target enables it. Adopting `~Escapable` publicly would mean
  enabling an experimental compiler feature on every host target.
- `~Escapable` values cannot be stored in `Array` or `Set`. The compiler
  reports `generic struct 'Array' requires that 'SpanSlice' conform to
  'Escapable'` and `type 'SpanSlice' does not conform to protocol
  'Escapable'`. No first-party code stores `ByteSlice` in a container today,
  so this does not block now, but it removes that option.
- The change is API-breaking. `ByteSlice` reaches 53 production files and 268
  public-signature sites and conforms to `Equatable, Hashable`. Every
  returning or accepting signature needs a `@_lifetime` annotation and every
  caller must respect the borrow.

**Decision: defer.** Keep `~Escapable` as the target end state for the
borrowed-view types, but do not convert in #872. It is the correct
compiler-enforced form of the invariant, but it depends on the `Lifetimes`
feature stabilizing and on an API-breaking sweep that overlaps #871
(`~Sendable` and borrowed-value isolation) and #873 (ownership features). Do
not enable an experimental feature host-wide as part of the Span migration.

**Consequence for #872.** Adopt the safe Span APIs inside the current
escapable views instead: derive a local `RawSpan` through a narrowly-scoped
`unsafe RawSpan(_unsafeBytes:)` bridge, use checked `RawSpan` subscripts or
`RawSpan.load(fromByteOffset:as:)` for byte reads, and use
`withTemporaryAllocation` for temporary padding buffers. Keep `RawSpan` local:
it cannot be returned from an ordinary computed property or stored in the
current escapable cursor without lifetime annotations. This path needs no
experimental feature flag and no public API break.

### #872 migration status

The production wire reader now uses checked `RawSpan` byte access in
`ByteSlice`, `TopicView`, `WireValueView`, and `WireKeyCursor`. The default
tokenizer scratch buffers in `WireReader` and `WireValueReader` now use
`withTemporaryAllocation` and `OutputSpan`; conversion to
`UnsafeBufferPointer` is kept inside the scoped `Span.withUnsafeBufferPointer`
interop call because `_JSONCore.JSONTokenizer` still accepts that pointer
type. The pointer-to-`RawSpan` bridges are localized at these borrowed-view
boundaries. No public wire signatures changed.

Pointer-based uses remaining in `Packages/AxolotyWire/Sources/AxolotyWire/`
are retained for these reasons:

| Use | Reason it remains |
|---|---|
| `ByteSlice`, `TopicView`, `BorrowedMessage`, `WireReader`, `WireWriter`, `WireValueView`, and `WireValueReader` pointer initializers and stored pointers | These are existing public or internal borrowing boundaries. `RawSpan` cannot be stored by ordinary escapable views without an API/lifetime change. `WireKeyCursor` creates a local `RawSpan` for each bounded load because storing a `RawSpan` would require lifetime annotations. |
| `ByteSlice.withBytes`, `ownedBytes`, and host `asString` | The callback and standard-library array/string APIs require pointer interop. The pointer stays scoped to the callback or is consumed by an owning copy. |
| `WireReader` tokenizer `UnsafeBufferPointer` parameters and `WireParserWorkspace.withStorage` | `_JSONCore.JSONTokenizer` and its destination protocol use pointer-based buffer parameters. A future `_JSONCore` Span interface would remove this boundary. |
| `WireParserWorkspace` inline storage and `UUID16` tuple mutation | These expose or mutate storage owned by an `InlineArray` or tuple. Their existing pointer access is scoped and there is no equivalent Span-based mutation interface for these container shapes. |
| `WireEvents` array encoding and `OwnedWireDataValidation` array validation | These use scoped Array pointer access to provide storage to existing synchronous wire APIs and tokenizer entry points. |
| `WireReader` aligned staging in `isValidJSONValue` | The staging buffer is a local `SIMD64` value; `withUnsafeMutableBytes` is the current way to initialize its bytes before an aligned tokenizer call. |

`TopicView.levelOffsets`/`levelLengths` and `WireBufferConfig.TopicLevelStorage`
already expose fixed `InlineArray` storage directly; no intermediate collection
copy exists to remove with borrow/mutate accessors.

## Explicitly out of scope

`Packages/AxolotyStaticRuntime/` and `Tests/AxolotyTests/ProtocolTrace/`
were excluded per instructions (reserved for a concurrent SIGBUS fix) and
were not audited or scanned by the gate.

## Swift 6.4 borrowed-value isolation and unchecked Sendable audit (#871)

### Borrowed values

Swift 6.4 supports negative conformance spelling with `~Sendable` (SE-0518).
This is the appropriate feature for the synchronous borrowed wire API: unlike
`~Escapable`, it does not require enabling the experimental `Lifetimes`
feature, does not change the pointer representation or ordinary call-site
lifetimes, and does not prohibit storing a view in a synchronous local or
fixed data structure. It prevents a borrowed value from satisfying a
`Sendable` constraint or crossing a checked asynchronous/isolation boundary.
`~Escapable` remains a separate possible lifetime-hardening step; it is not
required to establish the isolation invariant.

Explicit `~Sendable` is applied to every public wire value that carries or
derives a borrowed pointer:

| Type | Borrowed storage | Why it is explicitly non-Sendable |
|---|---|---|
| `ByteSlice` | Raw pointer and byte count | Its pointer refers to caller-owned storage and its accessors return derived slices. |
| `TopicView` | Topic pointer and parsed offsets | Topic-level slices borrow the input topic bytes. |
| `BorrowedMessage` | `TopicView` and payload `ByteSlice` | It combines both borrowed buffers and is the transport callback's synchronous view. |
| `WireReader` | Payload pointer and indexed ranges | Reads continue to refer to the caller's payload after construction. |
| `WireObjectField` | Payload pointer and key/value ranges | Fields are visitor-scoped projections into a `WireReader` buffer. |
| `WireValueView` | JSON value pointer and length | Nested values are passed only to synchronous borrowing visitors. |
| `WireValueReader` | JSON value pointer and length | Its child ranges and borrowed views derive from the caller's JSON bytes. |
| `BorrowedProtocolFrame` | Topic and payload `ByteSlice` values | Call `owned()` to copy the payload into a `ProtocolFrame` before an isolation hop. |

These declarations compile in the pinned Swift 6.4 host build and the
RISC-V Embedded Swift Core gate. The compile-fail fixture
`Tests/Support/lib/borrowed-action-sendability-probe.swift` passes each type
to `func requiresSendable<T: Sendable>(_ value: T)`; the paired check script
requires Swift to reject the fixture for a sendability/isolation diagnostic.
`ProtocolFrame` and decoded/owned value types remain `Sendable` where their
storage is owned.

### `@unchecked Sendable` inventory

`RuntimeModuleRegistration` was the one unnecessary production annotation
removed by this change. Its stored lifecycle callbacks are already
`@Sendable`, so ordinary structural `Sendable` conformance is sufficient.
Remaining annotations are retained only where the implementation relies on
external synchronization, framework confinement, or test-only synchronization
that the compiler cannot inspect:

| Declaration(s) | Classification and justification |
|---|---|
| `ManagedProcessSupervisor`, `FoundationProcessRunner`, `ServiceSignalHandler` (`Tools/AxolotyTooling/Services/AxolotyServiceSupervisor.swift`) | Needed. These host service objects coordinate `Process`, signal-source, and supervisor state across callbacks; the implementations serialize mutable state with their lock/queue or dispatch-source lifecycle. |
| `FoundationCommandExecution`, `CommandReaders`, `CommandPipeReader`, `FoundationProcessHandle` (`Tools/AxolotyTooling/Execution/FoundationCommandExecution.swift`) | Needed. Process and pipe callbacks run concurrently; shared state is guarded by locks and reader completion coordination. |
| `AxolotySignalLease`, `AxolotySignalMultiplexer` (`Tools/AxolotyTooling/Execution/CommandSignals.swift`) | Needed. These wrap process-global signal disposition and lease state behind synchronized operations. |
| `AxolotyCommandOutputCollector` (`Tools/AxolotyTooling/Execution/CommandOutput.swift`), `AxolotyCommandCancellation`, `AxolotyCancellationObservation` (`.../CommandCancellation.swift`), and `AxolotyCommandArtifactStore` (`.../CommandArtifacts.swift`) | Needed. Each exposes a small thread-safe reference handle whose mutable state is synchronized and shared among command execution callbacks. |
| `AxolotyCommandProgressTracker`, `AxolotyContinuousProgressRenderer`, `AxolotyInteractiveProgressRenderer` (`Tools/AxolotyTooling/Progress/`) | Needed. These are concurrent command-progress handles; their mutable progress/render state is serialized internally. |
| `FoundationResourceLease` (`Tools/AxolotyTooling/Leases/AxolotyResourceLease.swift`), `DispatchOverrunCancellation` (`Tools/AxolotyTooling/Check/AxolotyCheckEvents.swift`) | Needed. These bridge OS lease/dispatch cancellation handles across task boundaries and synchronize their lifecycle through the underlying OS primitive. |
| `RuntimeMQTTClient`, `MQTTBinding`, `RuntimeMQTTDelegate` (`Packages/AxolotyMQTT/Sources/`) | Needed. MQTT callbacks and async runtime operations share transport lifecycle state. `RuntimeMQTTClient` and `MQTTBinding` guard mutable state with `NIOLock`; the delegate only forwards owned callback values through the synchronized binding seam. |
| `SensorThingsTransactionToken` (`Packages/AxolotySensorThings/Sources/AxolotySensorThings/SensorThingsRuntime.swift`) | Needed. It is the shared invalidation flag for a configuration transaction; `SensorThingsConfiguration` checks it synchronously while the builder commits or rolls back, and runtime closures may observe invalidation from another task. |
| `HTTPHandler` (`Apps/AxolotyMCP/MCPHTTPServer.swift`), `BrokerConnectionHandler` (`Tests/AxolotyTestBroker/BrokerConnectionHandler.swift`) | Needed for NIO's `ChannelInboundHandler` contract. Handler state is channel/event-loop confined; it does not permit arbitrary concurrent mutation. |
| `InspectorSignalHandler` (`Apps/axoloty-inspect/InspectorSignalHandler.swift`) | Needed. The signal callback shares its one-shot signal state with the inspector shutdown path under the handler's synchronization. |
| `DeadlineResultBox`, `MCPProcessExit`, `MCPExecutableOutputDrain`, `ConfigurationBox`, `OneShotPhase`, `FakeSignalHandler`, `CompletionSignal`, `FailureBox`, `RuntimeTestIteratorBox`, `RuntimeTestDiagnosticIteratorBox`, `LargeStackResultBox`, and `HostTraceTransport` (`Apps/` and `Tests/`) | Test-only. These bridge test results, iterators, or protocol transports between the test task and a callback/task. Their state is either lock-protected, one-shot, or used under the test's explicit completion/ownership protocol; none is a shipped API. |
| `TimingRecordingRunner`, `TimingRecordingClock`, `TimingRecordingWorkspace`, `TimingSequenceCacheReader`, `ConcurrentPipeCapture`, its nested `State`, `FakeProcessRunner`, `FakePortProbe`, `FakeTempDirProvider`, `DevFakeProcessRunner`, `DevInjectedSignalHandler`, `DevInjectedSignalSource`, `DevStartupSignalPortProbe`, `DevTempDirProvider`, `AnyRunnerSource`, `ExitCodeBox`, `EmissionRecorder`, `MutableClock`, `RecordingRunner`, `RecordingFileSystem`, `RecordingIntegrationRunner`, `RecordingSequenceRunner`, `RecordingEventSink`, `ObservedLines`, `StreamRecorder`, `OutputRecorder`, `CheckTestClock`, `ManualOverrunTask`, `ManualOverrunScheduler`, `CheckEventRecorder`, `OverrunFiringRunner`, `DeadlineRecordingRunner`, `OutputEvents`, `CommandResultBox`, `LockedCounter`, `RecordingLease`, `RecordingLeaseManager`, `AdvancingLeaseManager` (`Tools/AxolotyToolingTests/`) | Test-only. These mutable fakes/recorders are shared by concurrent tests and callbacks. Each is intentionally a synchronization fixture (typically lock-protected or test-owned until its awaited completion); replacing them with actors would make synchronous test protocols and deterministic clock/runner controls asynchronous. |
| `FrameRecorder`, `ErrorRecorder`, `FakeMQTTClient` (`Packages/AxolotyMQTT/Tests/`), `BrokerClient`, `MessageCollector` (`Tests/AxolotyTestBrokerTests/`), `AsyncWaitResultBox`, `AsyncStreamBox` (`Tests/AxolotyTestSupport/`) | Test-only. They capture callback results/stream iteration across concurrency boundaries and provide the corresponding lock or single-consumer handoff. |

The test-only fakes are intentionally not promoted into production helpers.
The remaining production conformances describe synchronization or framework
confinement boundaries; removing `@unchecked` from those requires changing
the owner model, not changing only the declaration.
