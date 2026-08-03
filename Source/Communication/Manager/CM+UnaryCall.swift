// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import ErrorKit
import Foundation

/// The successful outcome of one unary Call/Return exchange.
public struct UnaryCallResult: Equatable, Sendable {
    /// The returned value as raw JSON text.
    public let result: String

    /// Optional execution information as raw JSON text.
    public let executionInfo: String?

    /// The identity of the provider that published the Return, when present.
    public let sourceId: String?

    /// Creates a unary call result.
    ///
    /// - Parameters:
    ///   - result: The returned value as raw JSON text.
    ///   - executionInfo: Optional execution information as raw JSON text.
    ///   - sourceId: The identity of the provider that published the Return.
    public init(result: String, executionInfo: String?, sourceId: String?) {
        self.result = result
        self.executionInfo = executionInfo
        self.sourceId = sourceId
    }
}

/// A structured error returned by a remote Call provider.
public struct RemoteCallFailure: Throwable, Equatable, Sendable {
    /// The provider-defined or predefined remote error code.
    public let code: Int

    /// The provider's error message.
    public let message: String

    /// Creates a remote call failure.
    ///
    /// - Parameters:
    ///   - code: The provider-defined or predefined remote error code.
    ///   - message: The provider's error message.
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// A stable, public-facing description of the remote failure.
    public var userFriendlyMessage: String {
        "Remote call failed (\(code)): \(message)"
    }
}

private enum UnaryCallWaitOutcome: Sendable {
    case response(ResponseEventSnapshot?)
    case timedOut
}

@MainActor
extension CommunicationManager {
    /// Performs one generic unary Call/Return exchange.
    ///
    /// Response observation is installed before the Call is published. The
    /// first correlated Return completes the exchange and releases observation
    /// ownership immediately; duplicate and later Returns are ignored. Use
    /// ``publishCall(_:)`` when multiple responses are desired.
    ///
    /// - Parameters:
    ///   - operation: The remote operation name.
    ///   - parameters: Optional parameters as raw JSON object or array text.
    ///   - context: An optional context filter used to select providers.
    ///   - timeout: The maximum duration to await a Return. Must be positive.
    /// - Returns: The remote result and optional execution information.
    /// - Throws: ``RemoteCallFailure`` when the provider returns a structured
    ///   error; ``AxolotyError/decodingFailure(type:reason:payload:)`` for a
    ///   malformed Return; ``AxolotyError/runtime(code:reason:)`` with
    ///   ``AxolotyError/RuntimeErrorCode/timedOut`` on timeout or
    ///   ``AxolotyError/RuntimeErrorCode/cancelled`` when the caller cancels;
    ///   or ``AxolotyError/invalidArgument(argument:reason:)`` for invalid
    ///   input.
    public func call(
        operation: String,
        parameters: String? = nil,
        context: ContextFilter? = nil,
        timeout: Duration
    ) async throws -> UnaryCallResult {
        guard timeout > .zero else {
            throw AxolotyError.invalidArgument(argument: "timeout", reason: "must be greater than zero")
        }

        do {
            try Task.checkCancellation()
            let event = try CallEvent.with(operation: operation, parameters: parameters, filter: context)
            let stream = await publishCall(event)
            let snapshot = try await waitForUnaryReturn(in: stream, timeout: timeout)
            return try decodeUnaryReturn(snapshot)
        } catch is CancellationError {
            throw AxolotyError.runtime(code: .cancelled, reason: "The unary call was cancelled")
        } catch let error as RemoteCallFailure {
            throw error
        } catch let error as AxolotyError {
            throw error
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    private func waitForUnaryReturn(
        in stream: AsyncStream<ResponseEventSnapshot>,
        timeout: Duration
    ) async throws -> ResponseEventSnapshot {
        try await withThrowingTaskGroup(of: UnaryCallWaitOutcome.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return .response(await iterator.next())
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            defer { group.cancelAll() }
            guard let outcome = try await group.next() else {
                throw AxolotyError.runtime(code: .streamEnded, reason: "The unary Return stream ended unexpectedly")
            }
            switch outcome {
            case let .response(snapshot):
                try Task.checkCancellation()
                guard let snapshot else {
                    throw AxolotyError.runtime(
                        code: .streamEnded,
                        reason: "The unary Return stream ended before a response was received"
                    )
                }
                return snapshot
            case .timedOut:
                throw AxolotyError.runtime(code: .timedOut, reason: "The unary call timed out")
            }
        }
    }

    private func decodeUnaryReturn(_ snapshot: ResponseEventSnapshot) throws -> UnaryCallResult {
        guard snapshot.eventType == WireEventType.returnEvent.rawValue,
              snapshot.correlationId != nil else {
            throw AxolotyError.decodingFailure(
                type: "ReturnEvent",
                reason: "The response is not a correlated Return",
                payload: snapshot.payload
            )
        }
        let event: ReturnEvent
        do {
            event = try JSONDecoder().decode(ReturnEvent.self, from: Data(snapshot.payload.utf8))
        } catch {
            throw AxolotyError.decodingFailure(
                type: "ReturnEvent",
                reason: "The correlated Return payload is malformed",
                payload: snapshot.payload
            )
        }

        if let error = event.data.error, event.data.result == nil {
            throw RemoteCallFailure(code: error.code, message: error.message)
        }
        guard event.data.error == nil, let result = event.data.result else {
            throw AxolotyError.decodingFailure(
                type: "ReturnEvent",
                reason: "The correlated Return must contain exactly one of result or error",
                payload: snapshot.payload
            )
        }
        return UnaryCallResult(result: result, executionInfo: event.data.executionInfo, sourceId: snapshot.sourceId)
    }
}
