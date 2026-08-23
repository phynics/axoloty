// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

/// Fixed configuration consumed exactly once by a static runtime.
public struct StaticRuntimeDefinition: ~Copyable {
    /// Families enabled for this firmware image.
    public let capabilities: ProtocolCapabilities
    /// Maximum accepted wire payload size.
    public let maximumPayloadBytes: Int

    /// Creates a bounded static definition.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumPayloadBytes: Int = 512
    ) {
        self.capabilities = capabilities
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

/// A synchronous, fixed-storage runtime for Embedded Swift.
///
/// One runtime owns exactly one ``ProtocolProcessor`` and one inline action
/// sink. Callers process a frame or local operation synchronously, drain its
/// actions before borrowed buffers leave scope, and then return to their
/// transport loop. No task, actor, Foundation value, or heap-backed registry
/// is part of this runtime.
public struct StaticRuntime<let capacity: Int>: ~Copyable {
    private var processor: ProtocolProcessor<capacity>
    private var subscriptions: ProtocolSubscriptionRegistry<capacity>
    private var sink: InlineProtocolActionSink<capacity>
    private let routeClassifier: ExactProtocolRouteClassifier

    /// Creates a runtime with a sealed capability profile and fixed limits.
    public init(
        capabilities: ProtocolCapabilities = .coatyCore3,
        maximumPayloadBytes: Int = 512
    ) {
        self.routeClassifier = ExactProtocolRouteClassifier(
            externalRoute: "external/wire-compat-v1/io-external-1"
        )
        self.processor = ProtocolProcessor<capacity>(
            capabilities: capabilities,
            maximumPayloadBytes: maximumPayloadBytes
        )
        self.subscriptions = ProtocolSubscriptionRegistry<capacity>()
        self.sink = InlineProtocolActionSink<capacity>()
    }

    /// Consumes fixed configuration and binds one exact route classifier.
    public init(
        definition: consuming StaticRuntimeDefinition,
        routeClassifier: ExactProtocolRouteClassifier
    ) {
        self.routeClassifier = routeClassifier
        self.processor = ProtocolProcessor<capacity>(
            capabilities: definition.capabilities,
            maximumPayloadBytes: definition.maximumPayloadBytes
        )
        self.subscriptions = ProtocolSubscriptionRegistry<capacity>()
        self.sink = InlineProtocolActionSink<capacity>()
    }

    /// The processor's fixed-storage state observation.
    public var state: ProtocolStateSnapshot { processor.state }

    /// Registers a synchronous numeric-context handler.
    public mutating func register(
        selector: ProtocolSubscriptionSelector,
        key: ByteSlice? = nil,
        handler: ProtocolHandlerEntry
    ) throws(ProtocolError) -> ProtocolSubscriptionToken {
        try subscriptions.register(selector: selector, key: key, handler: handler)
    }

    /// Removes a previously registered handler.
    public mutating func unregister(_ token: ProtocolSubscriptionToken) -> ProtocolUnregisterOutcome {
        subscriptions.unregister(token)
    }

    /// Processes one local operation and retains its action until ``drain``.
    public mutating func send(
        _ operation: ProtocolLocalOperation,
        nowMS: UInt32 = 0
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        return processor.processOutbound(operation, nowMS: nowMS, classifier: routeClassifier, sink: &sink)
    }

    /// Processes one inbound frame and retains its action until ``drain``.
    public mutating func receive(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        return processor.processInbound(frame, nowMS: nowMS, classifier: routeClassifier, sink: &sink)
    }

    /// Parses one caller-owned topic and payload synchronously, then routes
    /// the borrowed frame through the shared processor. The input buffers are
    /// borrowed only for the duration of this call.
    public mutating func receive(
        topic: ByteSlice,
        payload: ByteSlice,
        nowMS: UInt32
    ) -> ProtocolProcessOutcome {
        var result: ProtocolProcessOutcome = .rejected(.malformedFrame)
        topic.withBytes { pointer, length in
            payload.withBytes { payloadPointer, payloadLength in
                let view = TopicView(topicBytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                do throws(ProtocolError) {
                    let frame = try BorrowedProtocolFrame(
                        topic: view,
                        payload: ByteSlice(bytes: payloadPointer.assumingMemoryBound(to: UInt8.self), length: payloadLength)
                    )
                    result = self.receive(frame, nowMS: nowMS)
                } catch {
                    result = .rejected(error.code)
                }
            }
        }
        return result
    }

    /// Processes one inbound frame with a binding-owned route classifier.
    public mutating func receive<Classifier: ProtocolRouteClassifier>(
        _ frame: BorrowedProtocolFrame,
        nowMS: UInt32,
        classifier: Classifier
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        return processor.processInbound(frame, nowMS: nowMS, classifier: classifier, sink: &sink)
    }

    /// Processes one local operation with a binding-owned route classifier.
    public mutating func send<Classifier: ProtocolRouteClassifier>(
        _ operation: ProtocolLocalOperation,
        nowMS: UInt32 = 0,
        classifier: Classifier
    ) -> ProtocolProcessOutcome {
        guard sink.count == 0 else { return .rejected(.capacityExceeded) }
        sink.removeAll()
        return processor.processOutbound(operation, nowMS: nowMS, classifier: classifier, sink: &sink)
    }

    /// Expires all requests whose caller-supplied deadlines have elapsed.
    public mutating func expire(nowMS: UInt32) -> Bool {
        processor.expire(nowMS: nowMS)
    }

    /// Cancels one local request without emitting a wire operation.
    public mutating func cancel(correlationID: UUID16) -> Bool {
        processor.cancel(correlationID: correlationID)
    }

    /// Clears transport-local state so a reconnect can replay local state.
    public mutating func resetTransport() {
        processor.resetTransport()
        sink.removeAll()
    }

    /// Copies one active actor route into caller-owned transport storage.
    public func copyActorRoute(
        actorId: UUID16,
        to output: UnsafeMutablePointer<UInt8>,
        capacity outputCapacity: Int
    ) -> Int? {
        processor.copyActorRoute(actorId: actorId, to: output, capacity: outputCapacity)
    }

    /// Number of actions waiting for synchronous delivery.
    public var actionCount: Int { sink.count }

    /// Delivers and removes all retained actions before borrowed buffers leave scope.
    ///
    /// Registered handlers are invoked synchronously in slot order. The body
    /// is never retained by the runtime.
    @discardableResult
    public mutating func drain(_ body: (BorrowedProtocolAction) -> Void) -> Int {
        let count = sink.count
        for index in 0..<count {
            guard let action = sink[index] else { continue }
            body(action)
            if action.isApplicationDelivery {
                _ = subscriptions.dispatch(action)
            }
        }
        sink.removeAll()
        return count
    }

    /// Drains the synchronous action sink through the transport-facing name.
    @discardableResult
    public mutating func drainActions(_ body: (BorrowedProtocolAction) -> Void) -> Int {
        drain(body)
    }
}

/// The fixed profile used by the static device agent.
public typealias AxolotyStaticRuntime = StaticRuntime<16>
