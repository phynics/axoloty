// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Environment-derived broker defaults resolved from a string dictionary
/// (typically `ProcessInfo.processInfo.environment`).
///
/// Precedence is: CLI option > environment variable > built-in default.
/// This struct captures the middle layer so the parser can override
/// individual fields without re-reading the environment.
public struct InspectorEnvironmentValues: Equatable, Sendable {
    /// The broker host (default: `localhost`).
    public let host: String
    /// The broker port (default: `1883`).
    public let port: UInt16
    /// The broker username, if set.
    public let username: String?
    /// The broker password, if set.
    public let password: String?
    /// The Coaty namespace (default: `-`).
    public let namespace: String

    /// Built-in defaults with no environment overrides.
    public static let defaults = InspectorEnvironmentValues(
        host: "localhost",
        port: 1883,
        username: nil,
        password: nil,
        namespace: "-"
    )

    /// Creates values from a string dictionary, falling back to defaults
    /// for missing entries.
    public init(
        host: String,
        port: UInt16,
        username: String?,
        password: String?,
        namespace: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.namespace = namespace
    }

    /// Resolves values from an environment dictionary.
    public init(environment: [String: String]) {
        self.host = environment["AXOLOTY_MQTT_HOST"] ?? "localhost"
        self.port = UInt16(environment["AXOLOTY_MQTT_PORT"] ?? "") ?? 1883
        self.username = environment["AXOLOTY_MQTT_USERNAME"]
        self.password = environment["AXOLOTY_MQTT_PASSWORD"]
        self.namespace = environment["AXOLOTY_NAMESPACE"] ?? "-"
    }
}
