# Static-allocation message routing plan for Embedded Swift

Status: design plan for #208 Phase 2/3, scoped to the message routing and
wire decode hot path. This plan does not require ESP32-C6 hardware to draft;
it identifies the allocation sites in the current hot path and proposes a
borrow-semantics, compile-configurable design that works under Embedded Swift
constraints (no Foundation, no Codable, no `Any`, no reflection, no dynamic
protocol casts, no heap allocation in the steady state).

## Current hot path (allocation inventory)

```
MQTT PUBLISH arrives
    │
    ▼
MQTTNIOClient.handlePublish                          ← heap: [UInt8](info.payload)
    │                                                   heap: RawMQTTMessage(topic:payload:)
    │
    ├─ isRawTopic(topic:) → Bool                       ← heap: String (topic is already a String)
    │   YES → didReceiveRawMQTTMessage                 ← no additional alloc
    │          + ioValues.send(IoValueEventSnapshot)    ← heap: IoValueEventSnapshot(topic:payload:)
    │          RETURN
    │
    ├─ CommunicationTopic(topic)                       ← class (heap), String.components(separatedBy:)
    │   ← heap: [String] array of topic levels
    │   ← heap: CoatyUUID(uuidString:) construction
    │   ← heap: String? for eventTypeFilter, correlationId
    │
    ├─ String(bytes:encoding:) as UTF-8                ← heap: String from [UInt8]
    │
    ├─ ParsedMQTTMessage(topic:payload:)               ← value type but holds heap Strings
    │
    ▼
Broadcast<ParsedMQTTMessage>.send                     ← actor hop, continuation.yield
    │
    ├── routeAdvertiseSnapshot(parsed:)               ← BroadcastFamily lookup
    ├── routeOneWaySnapshot(parsed:)                   ← BroadcastFamily lookup
    └── routeSnapshot(parsed:)                        ← BroadcastFamily lookup
        │
        ▼ (consumer side, e.g. _observeAssociate)
    PayloadCoder.decode(parsed.payload)                ← heap: JSON parsing, Codable round-trip
        ← IkigaJSON JSONObject allocation
        ← IkigaJSONDecoder allocation
        ← Decodable init(from:) — class allocation for event types
        ← String allocations for decoded fields
```

### Allocation sites by category

| Category | Sites | Embedded-compatible? |
|---|---|---|
| **String allocations** | topic levels, payload UTF-8, eventTypeFilter, correlationId, decoded JSON fields | No — String is Foundation |
| **Array allocations** | `[UInt8]` from ByteBuffer, `[String]` from components(separatedBy:) | No — Array heap growth |
| **Class allocations** | CommunicationTopic (reference type), all CommunicationEvent subclasses, all CoatyObject subclasses | No — class instances are heap |
| **Actor hops** | Broadcast.send, BroadcastFamily.send | No — actors require runtime support |
| **Codable round-trip** | PayloadCoder.decode → IkigaJSON → Decodable init | No — Codable uses reflection, existential containers |
| **UUID construction** | CoatyUUID(uuidString:) | Partially — UUID can be a fixed 16-byte array |

## Proposed design

### Core principle: borrow, don't own

The embedded routing path operates on **borrows of a single receive buffer**.
No intermediate String, Array, or class is allocated in the steady state.
The buffer is a compile-time-sized stack allocation (or a statically reserved
arena) that holds the raw MQTT PUBLISH bytes. Every parse, lookup, and decode
operates on slices of this buffer.

### 1. Static receive buffer

```swift
// Compile-configurable via build settings
public struct WireBufferConfig {
    public static let maxTopicLength: Int = 128
    public static let maxPayloadSize: Int = 512
    public static let maxTopicLevels: Int = 7
    public static let maxSubscribers: Int = 8
    public static let maxBroadcastFamilyEntries: Int = 16
}
```

The MQTT client writes incoming PUBLISH payload directly into a
`StaticBuffer<WireBufferConfig.maxPayloadSize>` — a fixed-size `[UInt8]` wrapper
with a count. No `[UInt8](ByteBuffer.readableBytesView)` copy.

### 2. Zero-copy topic parsing

Replace `CommunicationTopic` (class, String-based) with a stack-allocated
`TopicView` that borrows the topic bytes from the receive buffer:

```swift
/// A borrow-based view into topic levels, parsed without allocation.
struct TopicView {
    // Level slices into the borrowed topic buffer
    var levels: [StaticRange]  // fixed-size array, maxTopicLevels

    init(topicBytes: UnsafeRawBufferPointer) {
        // Scan '/' in-place, record byte ranges — no String, no [String]
    }

    var protocolName: ByteSlice { ... }
    var version: ByteSlice { ... }
    var namespace: ByteSlice { ... }
    var eventName: ByteSlice { ... }
    var sourceId: ByteSlice { ... }
    var correlationId: ByteSlice? { ... }

    var eventType: CommunicationEventType? {
        // 3-byte comparison against eventName bytes — no String
    }
}
```

`ByteSlice` is a `(offset: Int, length: Int)` into the borrowed buffer. No
String is created for routing — the event type, namespace, and filter are
matched as byte sequences.

### 3. Static dispatch table (replacing Broadcast/BroadcastFamily)

The current `Broadcast<Element>` actor and `BroadcastFamily<Key,Element>`
actor use heap-allocated dictionaries and `AsyncStream` continuations. Under
Embedded Swift, replace with a compile-time dispatch table:

```swift
/// Static subscriber registry — no actors, no dictionaries, no heap.
struct StaticDispatchTable {
    // One slot per event type, compile-time maximum subscribers
    private var subscribers: [SubscriberSlot]

    struct SubscriberSlot {
        var active: Bool = false
        var handler: (@Sendable (BorrowedMessage) -> Void)?
    }
}
```

For the `BroadcastFamily` (keyed dispatch, e.g. Advertise by filter, Channel
by channel ID), use a compile-time-sized open-addressing hash table:

```swift
struct StaticFamilyTable<Key: Hashable> {
    private var entries: [FamilyEntry?]  // fixed-size, maxBroadcastFamilyEntries

    struct FamilyEntry {
        var key: Key
        var subscribers: StaticDispatchTable
    }
}
```

### 4. Borrow-based message routing

Replace the `ParsedMQTTMessage` value type (which holds heap Strings) with a
borrowed view:

```swift
/// A borrowed view of an incoming MQTT PUBLISH, zero-allocation.
struct BorrowedMessage {
    let topic: TopicView          // borrows from receive buffer
    let payload: UnsafeRawBufferPointer  // borrows from receive buffer
    let eventType: CommunicationEventType

    // Payload access without String allocation
    func decodePayload<T: WireDecodable>(as type: T.Type) -> Result<T, WireDecodeError>
}
```

The routing decision is made from `topic.eventType` (a 3-byte comparison)
without ever constructing a `CommunicationTopic` or calling
`String.components(separatedBy:)`.

### 5. Wire codec (Foundation-free decode)

Replace `PayloadCoder.decode` (IkigaJSON + Codable) with a direct
`WireDecodable` protocol that uses `IkigaJSONCore` tokenizer under the hood:

```swift
/// Foundation-free decode protocol for wire types.
protocol WireDecodable {
    init(from reader: borrowing WireReader) throws(WireDecodeError)
}

/// Foundation-free encode protocol for wire types.
protocol WireEncodable {
    func encode(to writer: inout WireWriter)
}

/// Zero-allocation JSON reader backed by IkigaJSONCore tokenizer.
struct WireReader {
    let tokenizer: IkigaJSONCore.Tokenizer
    let bytes: UnsafeRawBufferPointer

    func readString(key: StaticString) -> Result<ByteSlice, WireDecodeError>
    func readUUID(key: StaticString) -> Result<UUID16, WireDecodeError>
    func readInt(key: StaticString) -> Result<Int, WireDecodeError>
    func readRaw(key: StaticString) -> Result<ByteSlice, WireDecodeError>
}
```

Key fields are read by static string key (compile-time known), so the field
lookup is a direct tokenizer pass with no dictionary construction.

### 6. Compile-configurable subscriber limits

The number of concurrent subscribers per event type is a compile-time constant.
When the limit is exceeded, the subscription is rejected with a structured
error rather than growing a heap array:

```swift
// At compile time, configured for the target:
#if EMBEDDED
let maxSubscribers = WireBufferConfig.maxSubscribers  // 8
#else
let maxSubscribers = 256  // host runtime can grow dynamically
#endif
```

### 7. UUID as fixed 16-byte array

Replace `CoatyUUID` (which wraps Foundation `UUID`) with a
`UUID16: Hashable, Sendable` value type — a fixed 16-byte array. This
eliminates the class-based `CoatyUUID` and the Foundation dependency:

```swift
struct UUID16: Hashable, Sendable {
    let bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    init?(parsing bytes: some Collection<UInt8>) { ... }
    init?(parsing string: StaticString) { ... }
}
```

### 8. Routing flow (embedded path)

```
MQTT PUBLISH arrives
    │
    ▼
Write payload into StaticBuffer              ← no heap
    │
    ▼
TopicView(topicBytes: buffer.borrow())      ← stack, no heap
    │
    ├─ eventType = 3-byte comparison        ← no String
    │
    ├─ if .IoValue:
    │    dispatch to ioValue handlers       ← static table lookup
    │    RETURN
    │
    ├─ if raw topic:
    │    dispatch to rawMQTT handlers      ← static table lookup
    │    RETURN
    │
    ▼
WireReader(payload: buffer.borrow())        ← no heap
    │
    ├─ eventType-specific decode            ← WireDecodable.init(from:)
    │    (no Codable, no IkigaJSON JSONObject,
    │     no JSONDecoder allocation)
    │
    ▼
Dispatch to handler via StaticDispatchTable  ← no actor hop
```

### 9. Host vs. embedded adapter

The host runtime keeps its existing `Broadcast<Element>` actor for full
concurrency support. The embedded target uses the static dispatch table.
Both implement a common `MessageRouter` protocol:

```swift
protocol MessageRouter {
    func subscribe(eventType: CommunicationEventType,
                    _ handler: @Sendable (BorrowedMessage) -> Void) -> SubscriptionToken
    func unsubscribe(_ token: SubscriptionToken)
    func dispatch(_ message: BorrowedMessage)
}

// Host: backs the protocol with Broadcast actors
// Embedded: backs the protocol with StaticDispatchTable
```

### 10. What this plan does NOT change

- **IO routing** (RuleBasedIoRouter, IoSource, IoActor) — #115 already
  addressed this. The bucketed index from #116 is the production path. An
  embedded IO router would use the same bucketed approach with static arrays,
  but that is #96 Phase 2 work, not this plan.

- **The Coaty wire format** — topics, event codes, and payload JSON shapes
  are unchanged. This plan changes only how Axoloty parses and dispatches
  internally.

- **The MQTT transport** — mqtt-nio is not Embedded-compatible; the embedded
  transport is a separate concern (#96). This plan covers the routing and
  decode layer above whatever transport provides the raw bytes.

## Implementation phases (within #208)

### Phase A — WireReader/WireWriter primitives
- Implement `WireReader` on top of `IkigaJSONCore` tokenizer
- Implement `WireWriter` with JSON escaping
- Implement `ByteSlice` and `TopicView`
- Compile on Linux Embedded Swift (no hardware needed)

### Phase B — Static dispatch table
- Implement `StaticDispatchTable` and `StaticFamilyTable`
- Implement `BorrowedMessage`
- Compile on Linux Embedded Swift

### Phase C — Wire model conformances
- Conform base types (CoatyObject, Identity, event envelopes) to `WireDecodable`
- Differential test against existing PayloadCoder.decode output
- No production cutover yet — old path remains active

### Phase D — Host adapter bridge
- Implement `MessageRouter` protocol adapter wrapping existing `Broadcast` actors
- Implement embedded `StaticDispatchTable` adapter
- Route both through the same protocol

### Phase E — Production cutover (after all gates)
- Switch host production path to use `WireReader`/`WireDecodable` instead of Codable
- Remove Codable from wire-reachable types
- Run full compatibility suite

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| IkigaJSONCore tokenizer doesn't compile on ESP32-C6 | Phase 1 device gate (existing in #208); fall back to hand-rolled tokenizer if needed |
| Static subscriber limits cause runtime failures | Compile-time configurable; host runtime uses dynamic limits; embedded target rejects overflow with structured error |
| TopicView byte-slicing is error-prone | Property-based tests for all valid topic shapes; differential test against CommunicationTopic parsing |
| WireDecodable doesn't support unknown fields | WireReader preserves unknown fields as ByteSlice for round-trip (matching current RawJSONObjectContext behavior) |
| Shared model types need conditional compilation | Kill gate from #208: if shared models fail, use wire-DTO mapping (already approved fallback) |
