// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A diagnostic log level accepted by the inspector command line.
public enum InspectorLogLevel: String, CaseIterable, Equatable, Sendable {
    /// Emit every diagnostic message.
    case trace
    /// Emit debug and more severe diagnostic messages.
    case debug
    /// Emit informational and more severe diagnostic messages.
    case info
    /// Emit notices and more severe diagnostic messages.
    case notice
    /// Emit warnings and more severe diagnostic messages.
    case warning
    /// Emit errors only.
    case error

    /// The supported values in command-line help and configuration errors.
    public static var supportedValuesDescription: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// The output rendering mode for inspector records.
public enum InspectorOutputMode: String, Equatable, Sendable {
    /// Select `human` for a terminal, `ndjson` for a pipe.
    case auto
    /// One-line-per-event human-readable format.
    case human
    /// Newline-delimited JSON, one self-contained object per line.
    case ndjson
    /// A single JSON array emitted at completion (finite catalogue snapshot).
    case json
}

/// Broker connection parameters for the inspector.
///
/// The ``password`` is never surfaced through ``CustomStringConvertible``;
/// the synthesized description is overridden to redact credentials.
public struct InspectorConnectionConfiguration: Equatable, Sendable {
    /// The broker host name or address.
    public let host: String
    /// The broker TCP port.
    public let port: UInt16
    /// The Coaty namespace to observe.
    public let namespace: String
    /// Whether to use TLS for the broker connection.
    public let usesTLS: Bool
    /// The broker username, if any.
    public let username: String?
    /// The broker password, if any. Redacted in all descriptions.
    public let password: String?
    /// The maximum time to wait for broker readiness.
    public let connectTimeout: Duration

    /// Creates a connection configuration.
    public init(
        host: String,
        port: UInt16,
        namespace: String,
        usesTLS: Bool = false,
        username: String? = nil,
        password: String? = nil,
        connectTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.usesTLS = usesTLS
        self.username = username
        self.password = password
        self.connectTimeout = connectTimeout
    }
}

extension InspectorConnectionConfiguration: CustomStringConvertible {
    public var description: String {
        let creds = username != nil ? "username=***" : "no-credentials"
        let pass = password != nil ? " password=***" : ""
        return "InspectorConnectionConfiguration(host: \(host), port: \(port), namespace: \(namespace), tls: \(usesTLS), \(creds)\(pass), connectTimeout: \(connectTimeout))"
    }
}

/// The fully resolved inspector configuration combining command, connection,
/// and output preferences.
public struct InspectorConfiguration: Equatable, Sendable {
    /// The command to execute.
    public let command: InspectorCommand
    /// The broker connection parameters.
    public let connection: InspectorConnectionConfiguration
    /// The output rendering mode.
    public let output: InspectorOutputMode
    /// The diagnostic log level.
    public let logLevel: String
    /// Whether the password must be read from stdin before running.
    public let passwordFromStdin: Bool

    /// Creates a configuration.
    public init(
        command: InspectorCommand,
        connection: InspectorConnectionConfiguration,
        output: InspectorOutputMode = .auto,
        logLevel: String = "info",
        passwordFromStdin: Bool = false
    ) {
        self.command = command
        self.connection = connection
        self.output = output
        self.logLevel = logLevel
        self.passwordFromStdin = passwordFromStdin
    }
}

extension InspectorConfiguration: CustomStringConvertible {
    public var description: String {
        "InspectorConfiguration(command: \(command), connection: \(connection), output: \(output), logLevel: \(logLevel), passwordFromStdin: \(passwordFromStdin))"
    }
}
