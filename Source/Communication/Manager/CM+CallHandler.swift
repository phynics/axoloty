// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ErrorKit
import Foundation

/// The terminal result produced by a generic Call handler.
public enum CallHandlerResult: Sendable {
    /// A successful result encoded as raw JSON text.
    case success(result: String, executionInfo: String? = nil)

    /// A structured remote failure.
    case failure(code: Int, message: String, executionInfo: String? = nil)
}

/// Owns the lifetime of a registered generic Call handler.
///
/// Retain this object for as long as the handler should remain active. Calling
/// ``cancel()`` releases its Call observation, cancels in-flight handlers, and
/// prevents any later Return publication.
@MainActor
public final class CallHandlerRegistration {
    internal static let defaultDeduplicationWindow: Duration = .seconds(5)

    private var observationTask: Task<Void, Never>?
    private var handlerTasks: [String: Task<Void, Never>] = [:]
    private var activeCorrelations: Set<String> = []
    private var completedCorrelations: [String: ContinuousClock.Instant] = [:]
    private var cancellationAction: (() -> Void)?
    private let deduplicationWindow: Duration
    private let now: @MainActor () -> ContinuousClock.Instant

    internal init(
        cancellationAction: @escaping () -> Void,
        deduplicationWindow: Duration = CallHandlerRegistration.defaultDeduplicationWindow,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.cancellationAction = cancellationAction
        self.deduplicationWindow = deduplicationWindow
        self.now = now
    }

    /// Whether this registration has been cancelled.
    public private(set) var isCancelled = false

    /// Cancels observation and all handlers currently executing.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        observationTask?.cancel()
        observationTask = nil
        handlerTasks.values.forEach { $0.cancel() }
        handlerTasks.removeAll()
        activeCorrelations.removeAll()
        completedCorrelations.removeAll()
        cancellationAction?()
        cancellationAction = nil
    }

    internal func setObservationTask(_ task: Task<Void, Never>) {
        guard !isCancelled else {
            task.cancel()
            return
        }
        observationTask = task
    }

    internal func reserve(correlationId: String) -> Bool {
        guard !isCancelled else { return false }
        evictExpiredCompletions(at: now())
        guard completedCorrelations[correlationId] == nil,
              activeCorrelations.insert(correlationId).inserted else { return false }
        return true
    }

    internal func release(correlationId: String) {
        handlerTasks[correlationId] = nil
        activeCorrelations.remove(correlationId)
    }

    internal func setHandlerTask(_ task: Task<Void, Never>, correlationId: String) {
        guard !isCancelled,
              activeCorrelations.contains(correlationId),
              completedCorrelations[correlationId] == nil else {
            task.cancel()
            return
        }
        handlerTasks[correlationId] = task
    }

    internal func complete(correlationId: String) -> Bool {
        handlerTasks[correlationId] = nil
        activeCorrelations.remove(correlationId)
        guard !isCancelled else { return false }

        let completedAt = now()
        evictExpiredCompletions(at: completedAt)
        guard completedCorrelations[correlationId] == nil else {
            return false
        }
        completedCorrelations[correlationId] = completedAt
        return true
    }

    private func evictExpiredCompletions(at now: ContinuousClock.Instant) {
        let expiredCorrelationIds = completedCorrelations.compactMap { correlationId, completedAt in
            completedAt.duration(to: now) >= deduplicationWindow ? correlationId : nil
        }
        guard !expiredCorrelationIds.isEmpty else { return }

        expiredCorrelationIds.forEach { completedCorrelations[$0] = nil }
    }
}

@MainActor
extension CommunicationManager {
    /// Registers one generic provider-side Call handler.
    ///
    /// Incoming Calls are filtered by `operation`. When a Call includes a
    /// context filter, `context` must be non-nil and match it before `handler`
    /// is invoked. Completed correlation identifiers are suppressed for the
    /// registration's bounded deduplication window.
    ///
    /// - Parameters:
    ///   - operation: The remote operation name to handle.
    ///   - context: The provider object against which incoming context filters
    ///     are evaluated. Pass `nil` only for an unfiltered provider.
    ///   - handler: An asynchronous operation that returns either a successful
    ///     raw JSON result or a structured remote failure.
    /// - Returns: A lifetime owner whose cancellation unregisters the handler.
    /// - Throws: ``AxolotyError/invalidArgument(argument:reason:)`` when the
    ///   operation is not a valid event type filter, or a structured
    ///   subscription error when observation cannot be installed.
    public func registerCallHandler(
        operation: String,
        context: CoatyObject? = nil,
        handler: @escaping @Sendable (CallEventSnapshot) async throws -> CallHandlerResult
    ) async throws -> CallHandlerRegistration {
        try await registerCallHandler(
            operation: operation,
            context: context,
            deduplicationWindow: CallHandlerRegistration.defaultDeduplicationWindow,
            now: { ContinuousClock().now },
            handler: handler
        )
    }

    internal func registerCallHandler(
        operation: String,
        context: CoatyObject? = nil,
        deduplicationWindow: Duration,
        now: @escaping @MainActor () -> ContinuousClock.Instant,
        handler: @escaping @Sendable (CallEventSnapshot) async throws -> CallHandlerResult
    ) async throws -> CallHandlerRegistration {
        let stream = try await observeCallStream(operation: operation)
        let id = UUID()
        let registration = CallHandlerRegistration(
            cancellationAction: { [weak self] in
                self?.callHandlerRegistrations[id] = nil
            },
            deduplicationWindow: deduplicationWindow,
            now: now
        )
        callHandlerRegistrations[id] = registration

        let task = Task { @MainActor [weak self, weak registration] in
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let request = await iterator.next() {
                guard let self, let registration, !registration.isCancelled else { return }
                self.dispatchCall(request, context: context, handler: handler, registration: registration)
            }
        }
        registration.setObservationTask(task)
        return registration
    }

    private func dispatchCall(
        _ request: CallEventSnapshot,
        context: CoatyObject?,
        handler: @escaping @Sendable (CallEventSnapshot) async throws -> CallHandlerResult,
        registration: CallHandlerRegistration
    ) {
        guard let correlationId = request.correlationId, !correlationId.isEmpty else {
            log.warning("Ignored malformed Call without correlation id", metadata: [
                "operation": .string(request.operation),
            ])
            return
        }

        guard registration.reserve(correlationId: correlationId) else { return }

        if let parameters = request.parameters {
            do {
                let value = try JSONSerialization.jsonObject(with: Data(parameters.utf8))
                guard value is [String: Any] || value is [Any] else {
                    throw AxolotyError.decodingFailure(
                        type: "CallEvent",
                        reason: "Call parameters must be a JSON object or array",
                        payload: parameters
                    )
                }
            } catch {
                publishHandlerReturn(
                    .failure(code: -32602, message: "Malformed Call parameters"),
                    correlationId: correlationId,
                    registration: registration
                )
                return
            }
        }

        if let encodedFilter = request.filter {
            let filter: ContextFilter
            do {
                filter = try JSONDecoder().decode(ContextFilter.self, from: Data(encodedFilter.utf8))
            } catch {
                publishHandlerReturn(
                    .failure(code: -32602, message: "Malformed context filter"),
                    correlationId: correlationId,
                    registration: registration
                )
                return
            }
            guard ObjectMatcher.matchesFilter(obj: context, filter: filter) else {
                registration.release(correlationId: correlationId)
                return
            }
        }

        let task = Task { @MainActor [weak self, weak registration] in
            guard let self, let registration else { return }
            let result: CallHandlerResult
            do {
                result = try await handler(request)
            } catch is CancellationError {
                return
            } catch let error as RemoteCallFailure {
                result = .failure(code: error.code, message: error.message)
            } catch {
                let wrapped = error as? AxolotyError ?? AxolotyError.caught(error)
                self.log.error("Generic Call handler failed", metadata: [
                    "correlationId": .string(correlationId),
                    "operation": .string(request.operation),
                    "error": .string(ErrorKit.errorChainDescription(for: wrapped)),
                ])
                result = .failure(code: -32000, message: wrapped.userFriendlyMessage)
            }
            guard !Task.isCancelled else { return }
            self.publishHandlerReturn(result, correlationId: correlationId, registration: registration)
        }
        registration.setHandlerTask(task, correlationId: correlationId)
    }

    private func publishHandlerReturn(
        _ result: CallHandlerResult,
        correlationId: String,
        registration: CallHandlerRegistration
    ) {
        guard registration.complete(correlationId: correlationId) else { return }
        guard communicationState == .online else {
            log.warning("Generic Call Return publication failed because transport is offline", metadata: [
                "correlationId": .string(correlationId),
            ])
            return
        }
        let event: ReturnEvent
        switch result {
        case let .success(value, executionInfo):
            event = .with(result: value, executionInfo: executionInfo)
        case let .failure(code, message, executionInfo):
            event = .with(error: ReturnError(code: code, message: message), executionInfo: executionInfo)
        }
        publishReturn(event: event, correlationId: correlationId)
    }
}
