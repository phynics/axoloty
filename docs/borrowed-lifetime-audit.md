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
| `Packages/AxolotyWire/Sources/AxolotyWire/WireReader.swift` (`init(bytes:length:)`, `isValidJSONValue`) | `WireFieldIndex`/`WireFieldSlot` store `UInt16` offsets and lengths, never pointers (`WireReader+Tokenizer.swift:7`, `:34`); `self.bytes` is set once, directly, to the caller's original buffer — not to the temporary padded tokenizer workspace. Indexed reads later re-derive pointers from `self.bytes`, which the *caller* (not this initializer) guarantees stays alive. |
| `Packages/AxolotyWire/Sources/AxolotyWire/WireValueReader.swift` (`withArrayElements`, `withBorrowedArrayElements`) | `WireArrayElementDestination` stores element `Range<Int>`s (`WireValueReader.swift:289`, `:300`) computed inside a `withTemporaryAllocation` scope (`:210`, `:244`), not pointers; the temporary padded buffer never escapes. |
| `Packages/AxolotyWire/Sources/AxolotyWire/UUID16.swift`, `OwnedWireDataValidation.swift` | Return `Bool`/`WireDecodeError?`/`(Bool, Int)`, all consumed inside the closure. |
| `Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/BoundedDynamicObject.swift` (`edit`, `editEncodedFields`) | `ObjectEditor.init(source:)` copies every byte into its own `InlineArray` storage inside the initializer call, so the `editor` returned from `withUnsafeBytesOfRaw` is a fully owned value despite the visual shape resembling the bug. |
| `Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/ObjectPredicate.swift` (`withSegment`, `literalSlice`) | Explicitly documented: "The callback result is deliberately non-generic so a `ByteSlice` cannot be returned accidentally." |
| `Packages/AxolotyProtocol/Sources/AxolotyProtocol/InlineOwnedProtocolActionSink.swift` (`visit(at:_:)`) | Documented nonescaping visitor: "The action and every byte slice become invalid when this call returns." Fixed instance of the sink (`append`) now stores a copied `BorrowedProtocolRouteSnapshot`, not a `ByteSlice`. |
| `Source/Runtime/Executor/ProtocolExecutor+Outbound.swift` (`processOutboundOperation`) and `Source/Runtime/AxolotyRuntime.swift` (`dispatchActions(nowMS:)`) | `consumeAcceptedActions()` is called *inside* the `operation.payload.withUnsafeBufferPointer` closure (`ProtocolExecutor+Outbound.swift:131`, `:166`). The runtime passes `dispatchActions(nowMS:)` as that callback (`AxolotyRuntime.swift:871`), which converts every `BorrowedProtocolAction` to an owned action (`borrowed.owned()`, `:1196`) before the closure returns — the exact pattern the 880ff26 fix established. |
| `Packages/AxolotyProtocol/Sources/AxolotyProtocol/ProtocolProcessor.swift` (`advertisedObjectField`) | Returns a `ByteSlice?` that is a sub-view of the caller-supplied `payload: ByteSlice` *parameter* — not a new closure-local temporary. As valid as `payload` itself, which is the caller's existing borrow contract. |
| `Source/Runtime/AxolotyRuntimeDefinition+IO.swift` (`ioActor`, `dynamicIoActor`) | `Value.decodeIoPayload` / `DynamicIoValue.decodeIoPayload` copy into `BoundedIoBytes`/`BoundedJSONValue` before returning. |
| `Packages/AxolotyMQTT/Sources/AxolotyMQTT/MQTTBinding.swift` (`isActiveProfile(_:namespace:maximumTopicLength:)`, `classify(_:activeNamespace:maximumProfileTopicLength:)`) | Both closures return a `Bool` or a `ProtocolRouteClassification` (`MQTTBinding.swift:551`, `:575`), not a pointer-derived value. |
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
false positive against `Source/Runtime/Executor/ProtocolExecutor+Outbound.swift`
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

The script runs in required CI as the `no-escaping-borrows` node of
`Tests/Support/test-tiers.json`, with its self-test as
`support-no-escaping-borrows-self-test`.

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
  Lifetimes is enabled`. The embedded Core gate scripts
  (`Tests/Support/checks/check-embedded-swift-core.sh` and
  `check-embedded-swift-zenoh-core.sh`) pass the flag today; no host target
  enables it. Adopting `~Escapable` publicly would mean
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
`withTemporaryAllocation` and a `Span` over the padded buffer (`padded.span`); conversion to
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

`TopicView.levelOffsets`/`levelLengths` and `TopicLevelStorage` (file-level typealias in `WireBufferConfig.swift:9`)
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

Explicit `~Sendable` is applied to the public wire values below that carry or derive a borrowed pointer. `WireWriter` (`Packages/AxolotyWire/Sources/AxolotyWire/WireWriter.swift:19`) is public and stores a caller-owned `UnsafeMutablePointer<UInt8>` (`:21`), but it has no `~Sendable` marker and is not listed:

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
| `BorrowedProtocolInput`, `BorrowedProtocolDeliveryKey`, `BorrowedProtocolPublishTarget`, `BorrowedProtocolDelivery`, `BorrowedProtocolPublication`, `BorrowedIoAssociationTransition`, and `BorrowedProtocolAction` | Nested borrowed frames, selectors, payloads, and topic slices | These protocol-level wrappers carry wire borrows across the processor API; their `owned()` projections are the sendable boundary. |

No check script runs the compile-fail fixture
`Tests/Support/lib/borrowed-action-sendability-probe.swift`, which passes each
type to `func requiresSendable<T: Sendable>(_ value: T)`. The script that
required Swift to reject it, `check-borrowed-action-boundary.sh`, was removed in
`9c783147`. This audit did not re-verify that the declarations still compile on
the pinned toolchain.
`ProtocolFrame` and decoded/owned value types remain `Sendable` where their
storage is owned.

### `@unchecked Sendable` inventory

The production (non-test) declarations below carry their justification in code,
beside the declaration. Test-only conformances follow the table.

`RuntimeModuleRegistration` (`Source/Runtime/RuntimeModules.swift:53`) is a
structural `Sendable` struct. `SensorThingsTransactionToken`
(`Packages/AxolotySensorThings/Sources/AxolotySensorThings/SensorThingsRuntime.swift:260`)
also uses checked `Sendable` state. None of the following tooling declarations
carries an `@unchecked` annotation: `FoundationCommandExecution`,
`CommandReaders`, `FoundationProcessHandle`, `AxolotySignalLease`,
`AxolotyCommandOutputCollector`, `AxolotyCommandCancellation`,
`AxolotyCancellationObservation`, `AxolotyCommandArtifactStore`,
`AxolotyCommandProgressTracker`, `AxolotyContinuousProgressRenderer`,
`AxolotyInteractiveProgressRenderer`, and `FoundationResourceLease`.

| Declaration(s) | Classification and justification |
|---|---|
| `ServiceSignalHandler` (`Tools/AxolotyTooling/Execution/ServiceSignalHandler.swift:20`) | Needed. Signal sources and saved POSIX disposition pointers are non-Sendable; their lifecycle and interruption state live behind its mutex. |
| `CommandPipeReader` (`Tools/AxolotyTooling/Execution/FoundationCommandExecution.swift:709`) | Needed. Foundation file handles and pipe descriptors are non-Sendable; one reader owns reads while the mutex coordinates cancellation and closure. |
| `AxolotySignalMultiplexer` (`Tools/AxolotyTooling/Execution/CommandSignals.swift:32`) | Needed. Process signal-disposition pointers and the dispatch-source lifecycle are stored behind `Synchronization.Mutex`; callbacks are `@Sendable`. |
| `AxolotyCheckCompletionMailbox` (`Tools/AxolotyTooling/Check/AxolotyCheckScheduling.swift:106`) | Needed. The lock protects the completion queue; values crossing it are `Sendable`. |
| `AxolotyCheckEventDelivery` (`Tools/AxolotyTooling/Check/AxolotyCheckScheduling.swift:126`) | Needed. Delivery serializes the caller-supplied sink, including timer callbacks. |
| `DispatchTimer` and `DispatchOverrunCancellation` (`Tools/AxolotyTooling/Check/AxolotyCheckEvents.swift:154`, `:159`) | Needed. GCD does not mark dispatch sources `Sendable`; the unchecked wrapper is exclusively owned by the timer cancellation mutex. |
| `RuntimeMQTTClient`, `MQTTBinding`, `RuntimeMQTTDelegate` (`Packages/AxolotyMQTT/Sources/`) | Needed. `RuntimeMQTTClient` stores MQTTNIO client and event-loop objects with their own concurrency contracts. `MQTTBinding` serializes transport state with `NIOLock`; the delegate serializes callbacks, continuations, and timeout tasks with `NIOLock`. |
| `BrokerConnectionHandler` (`Packages/AxolotyTestBroker/Sources/AxolotyTestBroker/BrokerConnectionHandler.swift:9`) | Needed for NIO's `ChannelInboundHandler` contract. Handler state is confined to its channel event loop. |
| `ZenohBinding` (`Packages/AxolotyZenoh/Sources/AxolotyZenoh/ZenohBinding.swift:13`), `RuntimeTransportIngressRelay` (`Source/Runtime/AxolotyRuntime.swift:16`), `RuntimeTransportDiagnostics` (`Source/Runtime/AxolotyRuntimeTransportCounters.swift:47`) | **Open.** No reason comment sits beside these declarations, as the rule below requires. Add the reason, or replace the conformance with checked state. |
| `HTTPHandler`, `InspectorSignalHandler.State` (`phynics/axoloty-debug` sibling package) | Not in this checkout. Not verified here. |

Test-only conformances are not promoted into production helpers. Each one is a
synchronization fixture: lock-protected, one-shot, or owned by the test until its
awaited completion. Replacing one with an actor would make a synchronous test
protocol, or a deterministic clock or runner control, asynchronous. Current
declarations, by location:

- `Tools/AxolotyToolingTests/`: `ConcurrentCheckRunner`, `PackageRecordingRunner`,
  `OverrunFiringRunner`, `DeadlineRecordingRunner`, `OutputEvents`,
  `CommandResultBox`, `LockedCounter`, `CheckTestClock`, `ManualOverrunTask`,
  `ManualOverrunScheduler`, `CheckEventRecorder`, `OutputRecorder`,
  `RecordingRunner`, `RecordingFileSystem`, `RecordingIntegrationRunner`,
  `RecordingSequenceRunner`, `RecordingEventSink`, `RecordingLease`,
  `RecordingLeaseManager`, `AdvancingLeaseManager`, `ResourceLeaseWaitResult`,
  `StreamRecorder`, `ObservedLines`, `MutableClock`, `EmissionRecorder`.
- `Packages/AxolotyMQTT/Tests/`: `FrameRecorder`, `ErrorRecorder`, `FakeMQTTClient`.
- `Tests/AxolotyTestBrokerTests/`: `BrokerClient`, `MessageCollector`.
- `Tests/AxolotyTestSupport/`: `AsyncWaitResultBox`, `AsyncStreamBox`.
- `Tests/AxolotyTests/Runtime/`: `FailureBox`, `RuntimeTestIteratorBox`,
  `RuntimeTestDiagnosticIteratorBox`.
- `Packages/AxolotyProtocolTraceTestSupport/`: `LargeStackResultBox`,
  `RuntimeEventReceiptQueue`, `HostTraceTransport`.
- `Packages/AxolotyTransportContractTestSupport/`: `ContractFrameRecorder`,
  `ContractFailureRecorder`.
- `Packages/AxolotyZenoh/Tests/`: `FrameDeliverySignal`, `MQTTTraceCarrier`,
  `ZenohTraceCarrier`, `TraceFrameClock`, `FrameRecorder`, `ZenohContractFixture`,
  `FailureRecorder`, `RecoveryRecorder`, `NanosecondTestClock`, `CPeerOutput`,
  `BlockingFrameReceiver`.
- `Tests/Support/checks/check-axoloty-semver-consumer.sh`: `RecordingTransport`
  (Swift source embedded in the script).

Not found in this checkout, and possibly in the sibling `phynics/axoloty-debug`
package: `DeadlineResultBox`, `MCPProcessExit`, `MCPExecutableOutputDrain`,
`ConfigurationBox`, `OneShotPhase`, `FakeSignalHandler`, `CompletionSignal`,
`TimingRecordingRunner`, `TimingRecordingClock`, `TimingRecordingWorkspace`,
`TimingSequenceCacheReader`, `ConcurrentPipeCapture`, `FakeProcessRunner`,
`FakePortProbe`, `FakeTempDirProvider`, `DevFakeProcessRunner`,
`DevInjectedSignalHandler`, `DevInjectedSignalSource`,
`DevStartupSignalPortProbe`, `DevTempDirProvider`, `AnyRunnerSource`, and
`ExitCodeBox`.

The test-only fakes are intentionally not promoted into production helpers. Each
production unchecked conformance should have a one-line reason beside its
declaration; the three open entries above do not. Removing one requires replacing
its non-Sendable owner or framework boundary, not changing only the declaration.
