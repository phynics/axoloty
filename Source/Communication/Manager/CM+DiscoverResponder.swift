// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ErrorKit
import Foundation

/// A single correlation-validated Coaty Discover request delivered to a
/// registered discover responder.
///
/// The request is an immutable capability for one correlation: read the
/// ``snapshot`` to decide whether this host should respond, then call
/// ``resolve(_:)`` (or the object convenience overload) zero, one, or more
/// times to publish correlated `ResolveEvent`s. Declining a request is simply
/// not calling ``resolve`` — nothing is published.
///
/// The request keeps only a weak reference to its originating
/// ``DiscoverResponderRegistration``, so retaining the request does not retain
/// the manager or keep the responder alive.
///
/// The snapshot carries the correlation identifier too; the value here is the
/// same one, guaranteed non-empty (the manager drops correlation-less events
/// before invoking the handler).
public struct DiscoverRequest: Sendable {
    /// The parsed Discover event.
    public let snapshot: DiscoverEventSnapshot

    /// The non-empty correlation identifier for the correlated Resolve response.
    public let correlationId: String

    /// A weak capability back to the owning registration state.
    private let responderState: ResponderStateBox

    init(
        snapshot: DiscoverEventSnapshot,
        correlationId: String,
        responderState: ResponderStateBox
    ) {
        self.snapshot = snapshot
        self.correlationId = correlationId
        self.responderState = responderState
    }

    /// Publishes a Resolve event on this request's correlated topic.
    ///
    /// The manager overwrites the event's source identifier with its own
    /// identity before publication. Success means the response was accepted
    /// for local publication; it is not a broker acknowledgement.
    ///
    /// - Parameter event: The Resolve event to publish. A related-objects-only
    ///   event (no primary object) is rejected by the host encoder and throws
    ///   before anything is published.
    /// - Throws: ``AxolotyError`` when the registration has been cancelled,
    ///   the transport is offline (responses are never queued for later
    ///   publication), or the event cannot be encoded.
    @MainActor
    public func resolve(_ event: ResolveEvent) throws {
        guard responderState.isActive() == true else {
            throw responderState.invalidateError() ?? invalidRequestError
        }
        try responderState.publish(event, correlationId: correlationId)
    }

    /// Publishes a Resolve event carrying `object` (optionally with related
    /// objects and private data) on this request's correlated topic.
    ///
    /// Equivalent to ``resolve(_:)`` with
    /// `ResolveEvent.with(object:relatedObjects:privateData:)`.
    ///
    /// - Parameters:
    ///   - object: The primary resolved object. Required.
    ///   - relatedObjects: Optional related objects resolved alongside `object`.
    ///   - privateData: Optional application-specific private data.
    /// - Throws: ``AxolotyError`` when the registration has been cancelled,
    ///   the transport is offline (responses are never queued), or the event
    ///   cannot be encoded.
    @MainActor
    public func resolve(
        object: CoatyObject,
        relatedObjects: [CoatyObject]? = nil,
        privateData: [String: Any]? = nil
    ) throws {
        if let relatedObjects {
            try resolve(ResolveEvent.with(object: object, relatedObjects: relatedObjects, privateData: privateData))
        } else {
            try resolve(ResolveEvent.with(object: object, privateData: privateData))
        }
    }
}

/// Owns the lifetime of a registered discover responder.
///
/// Retain this object for as long as the responder should remain active.
/// Calling ``cancel()`` stops observation, causes any later ``resolve`` call
/// (even on a previously retained ``DiscoverRequest``) to throw, and
/// unregisters the responder from its manager.
@MainActor
public final class DiscoverResponderRegistration {
    /// Whether this registration has been cancelled.
    public private(set) var isCancelled = false

    private var _active = true
    private var invalidateErrorStorage: AxolotyError?
    private var observationTask: Task<Void, Never>?
    private var handlerTask: Task<Void, Never>?
    private var cancellationAction: (() -> Void)?

    internal init(cancellationAction: @escaping () -> Void) {
        self.cancellationAction = cancellationAction
    }

    /// Marks the registration inactive, cancels observation and any handler in
    /// flight, and unregisters it from the manager. Later ``resolve`` calls on
    /// previously created requests throw a cancelled-responder error.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        _active = false
        invalidateErrorStorage = responderCancelledError
        observationTask?.cancel()
        observationTask = nil
        handlerTask = nil
        cancellationAction?()
        cancellationAction = nil
    }

    /// Whether the registration is still active (not cancelled).
    internal var isActive: Bool {
        _active && !isCancelled
    }

    /// The error to throw for requests delivered by this registration after it
    /// has been cancelled, or `nil` while the registration is active.
    internal var invalidateError: AxolotyError? {
        invalidateErrorStorage
    }

    internal func setObservationTask(_ task: Task<Void, Never>) {
        guard !isCancelled else {
            task.cancel()
            return
        }
        observationTask = task
    }

    internal func setHandlerTask(_ task: Task<Void, Never>) {
        guard !isCancelled else {
            task.cancel()
            return
        }
        handlerTask = task
    }
}

@MainActor
extension CommunicationManager {

    /// Registers one generic discover responder.
    ///
    /// The responder receives every Discover event in the manager's namespace
    /// that carries a correlation identifier, as a ``DiscoverRequest`` whose
    /// ``DiscoverRequest/snapshot`` can be matched with an ordinary guard.
    /// Declining a request is returning without calling
    /// ``DiscoverRequest/resolve(_:)``; a matching request may be resolved
    /// zero, one, or multiple times (the built-in IoNode responder, for
    /// example, publishes one Resolve per configured node).
    ///
    /// The registration is non-throwing: there is no user input to validate.
    /// Response failures instead surface from ``DiscoverRequest/resolve(_:)``.
    ///
    /// - Parameter handler: An asynchronous operation invoked for every
    ///   correlation-carrying Discover event. Errors thrown by the handler are
    ///   logged with the correlation identifier and do not stop later
    ///   requests.
    /// - Returns: A lifetime owner whose cancellation unregisters the
    ///   responder and invalidates previously delivered requests.
    public func registerDiscoverResponder(
        handler: @escaping @MainActor @Sendable (DiscoverRequest) async throws -> Void
    ) async -> DiscoverResponderRegistration {
        let id = UUID()
        let registration = DiscoverResponderRegistration { [weak self] in
            self?.discoverResponderRegistrations[id] = nil
        }
        discoverResponderRegistrations[id] = registration

        let stream = await observeDiscoverStream()
        let task = Task { @MainActor [weak self, weak registration] in
            guard let self else { return }
            let state = ResponderStateBox(
                manager: self,
                isActive: { [weak registration] in registration?.isActive ?? false },
                invalidateError: { [weak registration] in registration?.invalidateError }
            )
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let snapshot = await iterator.next() {
                guard let registration, registration.isActive else { return }
                guard let correlationId = snapshot.correlationId, !correlationId.isEmpty else { continue }
                let request = DiscoverRequest(
                    snapshot: snapshot,
                    correlationId: correlationId,
                    responderState: state
                )
                let task = Task { @MainActor [weak self, weak registration] in
                    guard let self, let registration, registration.isActive else { return }
                    let log = self.log
                    do {
                        try await handler(request)
                    } catch is CancellationError {
                        return
                    } catch {
                        log.warning("Discover responder handler failed", metadata: [
                            "correlationId": .string(correlationId),
                            "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                        ])
                    }
                }
                registration.setHandlerTask(task)
            }
        }
        registration.setObservationTask(task)
        return registration
    }
}

/// A weak capability used by ``DiscoverRequest`` to reach the originating
/// registration and manager without retaining either.
@MainActor
final class ResponderStateBox {
    private weak var manager: CommunicationManager?
    let isActive: @MainActor () -> Bool
    let invalidateError: @MainActor () -> AxolotyError?

    init(
        manager: CommunicationManager,
        isActive: @escaping @MainActor () -> Bool,
        invalidateError: @escaping @MainActor () -> AxolotyError?
    ) {
        self.manager = manager
        self.isActive = isActive
        self.invalidateError = invalidateError
    }

    func publish(_ event: ResolveEvent, correlationId: String) throws {
        guard isActive() else {
            throw invalidateError() ?? responderCancelledError
        }
        guard let manager else {
            throw responderCancelledError
        }
        try manager.publishResolveThrowing(event: event, correlationId: correlationId)
    }
}

@MainActor
extension CommunicationManager {
    /// Publishes a Resolve event for a correlation id via the response topic.
    /// Throws instead of the internal `publishEvent` logging path, so an
    /// encoding failure reaches the responder call site and publishes nothing.
    func publishResolveThrowing(event: ResolveEvent, correlationId: String) throws {
        guard communicationState == .online else {
            throw AxolotyError.runtime(
                code: .streamEnded,
                reason: "Cannot publish a Resolve response while the transport is offline"
            )
        }
        event.sourceId = identity.objectId
        log.debug("Publishing response for correlation id", metadata: [
            "correlationId": .string(correlationId),
            "eventType": .string(WireEventType.resolve.rawValue),
        ])
        let topic = TopicBuilder.publishTopic(
            components: .init(namespace: namespace, eventType: .resolve, correlationId: correlationId),
            sourceId: identity.objectId
        )
        do {
            let bytes = try HostWireAdapter.encodeEvent(event)
            client.publish(topic, message: bytes)
        } catch {
            throw AxolotyError.caught(error)
        }
    }
}

/// The error thrown by ``DiscoverRequest/resolve(_:)`` after the responder has
/// been cancelled.
private let responderCancelledError = AxolotyError.runtime(
    code: .cancelled,
    reason: "The discover responder was cancelled"
)

/// The error thrown when a request's responder state is already invalid.
private let invalidRequestError = AxolotyError.runtime(
    code: .cancelled,
    reason: "The discover responder request is no longer valid"
)
