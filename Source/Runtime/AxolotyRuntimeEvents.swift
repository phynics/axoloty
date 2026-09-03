// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// Provenance of a normalized runtime event.
public enum RuntimeEventProvenance: Sendable, Equatable {
    /// Decoded from an owned transport frame.
    case transport
    /// Created by a local runtime operation.
    case local
    /// Replayed by a bounded test or diagnostic adapter.
    case replay
}

/// The thirteen closed Coaty Core families exposed by the host runtime.
public enum RuntimeEventFamily: Sendable, Equatable, CaseIterable {
    case advertise, deadvertise, channel, associate, ioValue
    case discover, resolve, query, retrieve, update, complete, call, returnEvent
}

/// Context attached to a normalized event. It deliberately contains no raw
/// MQTT topic or transport-owned buffer.
public struct RuntimeEventContext: Sendable, Equatable {
    /// The source that produced the event.
    public let sourceID: UUID16
    /// The request correlation, when the family carries one.
    public let correlationID: UUID16?
    /// The configured namespace.
    public let namespace: String
    /// Binding-owned route classification.
    public let route: ProtocolRouteClassification
    /// The semantic Channel identifier when this event was delivered on a Channel.
    ///
    /// This is copied from the typed protocol delivery key. It intentionally
    /// contains no transport topic or broker-specific routing detail.
    public let channelIdentifier: String?
    /// Monotonic receipt time supplied by the binding.
    public let receiptTimeMS: UInt32
    /// Whether the event came from transport, a local operation, or replay.
    public let provenance: RuntimeEventProvenance

    /// Creates event context from boundary-owned values.
    public init(
        sourceID: UUID16,
        correlationID: UUID16? = nil,
        namespace: String,
        route: ProtocolRouteClassification = .coaty,
        channelIdentifier: String? = nil,
        receiptTimeMS: UInt32,
        provenance: RuntimeEventProvenance = .transport
    ) {
        self.sourceID = sourceID
        self.correlationID = correlationID
        self.namespace = namespace
        self.route = route
        self.channelIdentifier = channelIdentifier
        self.receiptTimeMS = receiptTimeMS
        self.provenance = provenance
    }
}

/// Application stream buffering policy. Transport ingress never uses a lossy
/// policy; these policies apply only after normalized actions are owned.
public enum RuntimeBufferingPolicy: Sendable, Equatable {
    /// Fails the runtime after ``AsyncStream`` reports a rejected event.
    /// The triggering value is not delivered because `AsyncStream` has no
    /// synchronous reservation API; callers that require lossless delivery
    /// must use a larger bound or a request/response API.
    case failAfterDrop(capacity: Int)
    case fail(capacity: Int)
    case dropOldest(capacity: Int)
    case dropNewest(capacity: Int)
    case coalesceLatest
}

/// A typed selector for one bounded application event stream.
public enum RuntimeEventSelector: Sendable, Equatable {
    /// Matches every action in one Coaty family.
    case family(RuntimeEventFamily)
    /// Matches Advertise actions, optionally narrowed by an object type.
    case advertise(objectType: String?)
    /// Matches a Channel identifier.
    case channel(identifier: String)
    /// Matches IoValue actions addressed to one actor.
    case ioActor(UUID16)
    /// Matches one correlated response family and identity.
    case correlatedResponse(capability: ProtocolCapability, correlationID: UUID16)
}

/// A bounded asynchronous sequence registered before runtime startup.
public struct RuntimeEventStream: AsyncSequence, Sendable {
    /// The value yielded by this stream.
    public typealias Element = RuntimeEventValue

    private let stream: AsyncStream<RuntimeEventValue>
    private let continuation: AsyncStream<RuntimeEventValue>.Continuation

    init(stream: AsyncStream<RuntimeEventValue>, continuation: AsyncStream<RuntimeEventValue>.Continuation) {
        self.stream = stream
        self.continuation = continuation
    }

    /// Creates an iterator over owned, normalized event values.
    public func makeAsyncIterator() -> AsyncStream<RuntimeEventValue>.Iterator {
        stream.makeAsyncIterator()
    }

    /// Finishes the stream for a module-owned product during runtime shutdown.
    @_spi(AxolotyRuntimeAdapter)
    public func finish() {
        continuation.finish()
    }
}

struct RuntimeEventRegistration: Sendable {
    let selector: RuntimeEventSelector
    let policy: RuntimeBufferingPolicy
    let continuation: AsyncStream<RuntimeEventValue>.Continuation
}

/// A normalized event delivered by a host runtime stream.
public struct RuntimeEventValue: Sendable, Equatable {
    /// The closed family.
    public let family: RuntimeEventFamily
    /// Boundary-owned event context.
    public let context: RuntimeEventContext
    /// Owned, family-codec payload bytes. These bytes are never borrowed.
    public let value: [UInt8]

    /// Creates an owned normalized event value.
    public init(family: RuntimeEventFamily, context: RuntimeEventContext, value: [UInt8]) {
        self.family = family
        self.context = context
        self.value = value
    }
}

/// A bounded runtime event, suitable for an asynchronous consumer.
public enum RuntimeEvent: Sendable, Equatable {
    /// An owned protocol action was delivered to a registered handler.
    case invocation(RuntimeInvocation)
    /// A protocol transition completed with a receipt.
    case transition(RuntimeReceipt)
}
