// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The serve subcommand to execute.
public enum AxolotyServeCommand: Equatable, Sendable {
    /// Start a local Mosquitto broker.
    case mqtt(MQTTServiceConfiguration)
    /// Start an Axoloty-aware MCP server.
    case mcp(MCPServiceConfiguration)
    /// Start both MQTT and MCP as a supervised development stack.
    case development(DevelopmentServiceConfiguration)
}

/// Log level for managed services.
public enum ServiceLogLevel: String, Sendable, Equatable, CaseIterable {
    case error, warning, info, debug
}

/// Output mode for serve commands.
public enum ServeOutputMode: String, Sendable, Equatable, CaseIterable {
    case human, json
}

/// MCP transport mode.
public enum MCPTransport: String, Sendable, Equatable, CaseIterable {
    case stdio, http
}

/// Configuration for the local MQTT broker service.
public struct MQTTServiceConfiguration: Equatable, Sendable {
    /// Native listen address.
    public let listenHost: String
    /// MQTT port.
    public let port: UInt16
    /// Broker log verbosity.
    public let logLevel: ServiceLogLevel
    /// Structured output mode.
    public let output: ServeOutputMode

    /// Creates an MQTT service configuration.
    public init(
        listenHost: String = "127.0.0.1",
        port: UInt16 = 1883,
        logLevel: ServiceLogLevel = .info,
        output: ServeOutputMode = .human
    ) {
        self.listenHost = listenHost
        self.port = port
        self.logLevel = logLevel
        self.output = output
    }
}

/// Configuration for the MCP server service.
public struct MCPServiceConfiguration: Equatable, Sendable {
    /// MCP transport (stdio or http).
    public let transport: MCPTransport
    /// HTTP listener address (HTTP only).
    public let listenHost: String
    /// HTTP listener port (HTTP only).
    public let listenPort: UInt16
    /// MCP endpoint path (HTTP only).
    public let path: String
    /// MQTT broker host.
    public let brokerHost: String
    /// MQTT broker port.
    public let brokerPort: UInt16
    /// Coaty namespace.
    public let namespace: String
    /// Broker readiness deadline (e.g. ``10s``).
    public let connectTimeout: String
    /// Structured output mode (HTTP only).
    public let output: ServeOutputMode

    /// Creates an MCP service configuration.
    public init(
        transport: MCPTransport,
        listenHost: String = "127.0.0.1",
        listenPort: UInt16 = 8765,
        path: String = "/mcp",
        brokerHost: String = "localhost",
        brokerPort: UInt16 = 1883,
        namespace: String = "-",
        connectTimeout: String = "10s",
        output: ServeOutputMode = .human
    ) {
        self.transport = transport
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.path = path
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort
        self.namespace = namespace
        self.connectTimeout = connectTimeout
        self.output = output
    }
}

/// Configuration for the combined development stack.
public struct DevelopmentServiceConfiguration: Equatable, Sendable {
    /// MQTT service configuration.
    public let mqtt: MQTTServiceConfiguration
    /// MCP service configuration.
    public let mcp: MCPServiceConfiguration
    /// Coaty namespace.
    public let namespace: String
    /// Structured output mode.
    public let output: ServeOutputMode

    /// Creates a development service configuration.
    public init(
        mqtt: MQTTServiceConfiguration,
        mcp: MCPServiceConfiguration,
        namespace: String,
        output: ServeOutputMode
    ) {
        self.mqtt = mqtt
        self.mcp = mcp
        self.namespace = namespace
        self.output = output
    }
}
