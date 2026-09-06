// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The typed error boundary for inspector parser and application failures.
///
/// All errors that originate within the inspector are represented by this
/// type. Foreign errors from ``Axoloty`` are translated at the session
/// boundary into the appropriate case, preserving the cause chain for
/// diagnostic logging while exposing a stable user-facing message.
public enum InspectorError: Error, Equatable, Sendable {
    /// A command-line argument or its value was invalid or missing.
    case invalidArguments(reason: String)
    /// A configuration field failed validation.
    case invalidConfiguration(field: String, reason: String)
    /// The broker could not be reached or the connection was lost.
    case connectionUnavailable(reason: String)
    /// Broker authentication failed.
    case authenticationFailed
    /// A Coaty protocol-level failure occurred after connection.
    case protocolFailure(reason: String)
    /// Writing to the output stream failed.
    case outputFailure(reason: String)
    /// The operator interrupted the operation (SIGINT or SIGTERM).
    case interrupted
    /// An unexpected internal failure occurred.
    case internalFailure(reason: String)

    /// A stable, user-facing description suitable for CLI output.
    public var userFriendlyMessage: String {
        switch self {
        case let .invalidArguments(reason):
            "invalid arguments: \(reason)"
        case let .invalidConfiguration(field, reason):
            "\(field): \(reason)"
        case let .connectionUnavailable(reason):
            "connection unavailable: \(reason)"
        case .authenticationFailed:
            "authentication failed"
        case let .protocolFailure(reason):
            "protocol failure: \(reason)"
        case let .outputFailure(reason):
            "output failure: \(reason)"
        case .interrupted:
            "interrupted"
        case let .internalFailure(reason):
            "internal failure: \(reason)"
        }
    }

    /// The exit code corresponding to this error category.
    public var exitCode: Int32 {
        switch self {
        case .invalidArguments, .invalidConfiguration:
            64
        case .connectionUnavailable, .authenticationFailed:
            69
        case .protocolFailure, .outputFailure, .internalFailure:
            1
        case .interrupted:
            130
        }
    }
}
