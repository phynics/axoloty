// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Errors produced while parsing ``AxolotyServeCommand`` arguments.
public enum AxolotyServeError: Error, Equatable, Sendable {
    /// The serve subcommand was not recognized.
    case unknownSubcommand(String)
    /// No serve subcommand was provided.
    case missingSubcommand
    /// A port value was not a valid positive ``UInt16``.
    case invalidPort(String)
    /// A broker readiness timeout was not a positive bounded duration.
    case invalidDuration(String)
    /// The transport was not ``MCPTransport/stdio`` or ``MCPTransport/http``.
    case invalidTransport(String)
    /// The endpoint path did not start with ``/``.
    case invalidPath(String)
    /// The output mode was not ``ServeOutputMode/human`` or ``ServeOutputMode/json``.
    case invalidOutputMode(String)
    /// The log level was not a recognized value.
    case invalidLogLevel(String)
    /// An option was provided more than once.
    case duplicateOption(String)
    /// A non-loopback HTTP listen host was rejected.
    case nonLoopbackHTTPBinding(String)
    /// An unknown option was provided.
    case unknownOption(String)
    /// A flag that requires a value was provided without one.
    case missingValue(String)
    /// The required ``--transport`` option was not provided.
    case missingTransport
    /// An HTTP-only option was used with stdio transport.
    case httpOnlyOption(String)

    /// A human-readable explanation suitable for stderr output.
    public var userFriendlyMessage: String {
        switch self {
        case .unknownSubcommand(let cmd):
            return "unknown serve subcommand: \(cmd) (expected mqtt, mcp, or dev)"
        case .missingSubcommand:
            return "serve requires a subcommand: mqtt, mcp, or dev"
        case .invalidPort(let value):
            return "invalid port: \(value) (must be 1–65535)"
        case .invalidDuration(let value):
            return "invalid connect timeout: \(value) (use a positive duration such as 10s, 2m, or 1h; maximum 24h)"
        case .invalidTransport(let value):
            return "invalid transport: \(value) (must be stdio or http)"
        case .invalidPath(let value):
            return "invalid endpoint path: \(value) (must start with /)"
        case .invalidOutputMode(let value):
            return "invalid output mode: \(value) (must be human or json)"
        case .invalidLogLevel(let value):
            return "invalid log level: \(value) (must be error, warning, info, or debug)"
        case .duplicateOption(let name):
            return "duplicate option: --\(name)"
        case .nonLoopbackHTTPBinding(let host):
            return "non-loopback HTTP binding rejected: \(host) (use 127.0.0.1 or localhost)"
        case .unknownOption(let name):
            return "unknown option: --\(name)"
        case .missingValue(let name):
            return "option --\(name) requires a value"
        case .missingTransport:
            return "serve mcp requires --transport stdio or http"
        case .httpOnlyOption(let name):
            return "option --\(name) is only valid with --transport http"
        }
    }
}

/// Parses ``AxolotyServeCommand`` arguments from the command line.
public struct AxolotyServeParser: Sendable {

    /// Creates a serve parser.
    public init() {}

    /// Parses serve subcommand arguments.
    ///
    /// - Parameters:
    ///   - arguments: Arguments after the `serve` keyword (e.g. `["mqtt", "--port", "1883"]`).
    ///   - environment: The environment variable map for default resolution.
    /// - Returns: The parsed command or a structured error.
    public func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<AxolotyServeCommand, AxolotyServeError> {
        guard let subcommand = arguments.first else {
            return .failure(.missingSubcommand)
        }
        let rest = Array(arguments.dropFirst())
        if rest == ["--help"], ["mqtt", "mcp", "dev"].contains(subcommand) {
            return .success(.help(subcommand))
        }
        switch subcommand {
        case "mqtt":
            return parseMQTT(arguments: rest, environment: environment)
        case "mcp":
            return parseMCP(arguments: rest, environment: environment)
        case "dev":
            return parseDevelopment(arguments: rest, environment: environment)
        default:
            return .failure(.unknownSubcommand(subcommand))
        }
    }

    // MARK: - Flag parsing

    private struct ParsedFlags {
        var values: [String: String] = [:]
        var seen: Set<String> = []
    }

    private func parseFlags(_ args: [String]) -> Result<ParsedFlags, AxolotyServeError> {
        var flags = ParsedFlags()
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else {
                return .failure(.unknownOption(arg))
            }
            let name: String
            let value: String
            if let eq = arg.firstIndex(of: "=") {
                name = String(arg[arg.index(arg.startIndex, offsetBy: 2)..<eq])
                value = String(arg[arg.index(after: eq)...])
            } else {
                name = String(arg.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    value = args[i + 1]
                    i += 1
                } else {
                    value = ""
                }
            }
            guard !name.isEmpty else {
                return .failure(.unknownOption(arg))
            }
            if flags.seen.contains(name) {
                return .failure(.duplicateOption(name))
            }
            flags.values[name] = value
            flags.seen.insert(name)
            i += 1
        }
        return .success(flags)
    }

    /// Returns the value for a known flag, or nil if it was not provided.
    /// Fails if the flag was provided without a value.
    private func flagValue(_ flags: ParsedFlags, _ name: String) -> Result<String?, AxolotyServeError> {
        guard let value = flags.values[name] else {
            return .success(nil)
        }
        if value.isEmpty {
            return .failure(.missingValue(name))
        }
        return .success(value)
    }

    // MARK: - MQTT

    private static let mqttKnownOptions: Set<String> = [
        "listen-host", "port", "output", "log-level",
    ]

    private func parseMQTT(
        arguments: [String],
        environment: [String: String]
    ) -> Result<AxolotyServeCommand, AxolotyServeError> {
        let flags: ParsedFlags
        switch parseFlags(arguments) {
        case .success(let parsed): flags = parsed
        case .failure(let err): return .failure(err)
        }

        for key in flags.values.keys {
            guard Self.mqttKnownOptions.contains(key) else {
                return .failure(.unknownOption(key))
            }
        }
        for (key, value) in flags.values {
            if value.isEmpty {
                return .failure(.missingValue(key))
            }
        }

        let listenHost = flags.values["listen-host"] ?? "127.0.0.1"
        let port: UInt16
        switch resolvePort(flags.values["port"], environment: environment, key: "AXOLOTY_MQTT_PORT", default: 1883) {
        case .success(let p): port = p
        case .failure(let e): return .failure(e)
        }

        let output: ServeOutputMode
        switch resolveOutputMode(flags.values["output"]) {
        case .success(let o): output = o
        case .failure(let e): return .failure(e)
        }

        let logLevel: ServiceLogLevel
        switch resolveLogLevel(flags.values["log-level"]) {
        case .success(let l): logLevel = l
        case .failure(let e): return .failure(e)
        }

        return .success(.mqtt(MQTTServiceConfiguration(
            listenHost: listenHost,
            port: port,
            logLevel: logLevel,
            output: output
        )))
    }

    // MARK: - MCP

    private static let mcpKnownOptions: Set<String> = [
        "transport", "listen-host", "listen-port", "path",
        "broker-host", "broker-port", "namespace",
        "connect-timeout", "output",
    ]

    private static let mcpHTTPOnlyOptions: Set<String> = [
        "listen-host", "listen-port", "path", "output",
    ]

    private func parseMCP(
        arguments: [String],
        environment: [String: String]
    ) -> Result<AxolotyServeCommand, AxolotyServeError> {
        let flags: ParsedFlags
        switch parseFlags(arguments) {
        case .success(let parsed): flags = parsed
        case .failure(let err): return .failure(err)
        }

        for key in flags.values.keys {
            guard Self.mcpKnownOptions.contains(key) else {
                return .failure(.unknownOption(key))
            }
        }

        guard let transportRaw = flags.values["transport"] else {
            return .failure(.missingTransport)
        }
        guard let transport = MCPTransport(rawValue: transportRaw) else {
            return .failure(.invalidTransport(transportRaw))
        }

        if transport == .stdio {
            for key in Self.mcpHTTPOnlyOptions {
                if flags.values[key] != nil {
                    return .failure(.httpOnlyOption(key))
                }
            }
        }
        for (key, value) in flags.values {
            if value.isEmpty {
                return .failure(.missingValue(key))
            }
        }

        let brokerHost = flags.values["broker-host"]
            ?? environment["AXOLOTY_MQTT_HOST"]
            ?? "localhost"
        let brokerPort: UInt16
        switch resolvePort(flags.values["broker-port"], environment: environment, key: "AXOLOTY_MQTT_PORT", default: 1883) {
        case .success(let p): brokerPort = p
        case .failure(let e): return .failure(e)
        }
        let namespace = flags.values["namespace"]
            ?? environment["AXOLOTY_NAMESPACE"]
            ?? "-"

        let listenHost = flags.values["listen-host"]
            ?? environment["AXOLOTY_MCP_HOST"]
            ?? "127.0.0.1"
        let listenPort: UInt16
        switch resolvePort(flags.values["listen-port"], environment: environment, key: "AXOLOTY_MCP_PORT", default: 8765) {
        case .success(let p): listenPort = p
        case .failure(let e): return .failure(e)
        }
        let path = flags.values["path"]
            ?? environment["AXOLOTY_MCP_PATH"]
            ?? "/mcp"

        if transport == .http {
            if !isLoopback(listenHost) {
                return .failure(.nonLoopbackHTTPBinding(listenHost))
            }
        }

        if transport == .http {
            guard path.hasPrefix("/") else {
                return .failure(.invalidPath(path))
            }
        }

        let connectTimeout = flags.values["connect-timeout"] ?? "10s"
        guard Self.isValidConnectTimeout(connectTimeout) else {
            return .failure(.invalidDuration(connectTimeout))
        }

        let output: ServeOutputMode
        switch resolveOutputMode(flags.values["output"]) {
        case .success(let o): output = o
        case .failure(let e): return .failure(e)
        }

        return .success(.mcp(MCPServiceConfiguration(
            transport: transport,
            listenHost: listenHost,
            listenPort: listenPort,
            path: path,
            brokerHost: brokerHost,
            brokerPort: brokerPort,
            namespace: namespace,
            connectTimeout: connectTimeout,
            output: output
        )))
    }

    // MARK: - Development

    private static let devKnownOptions: Set<String> = [
        "namespace", "mqtt-port", "mcp-port", "output",
    ]

    private func parseDevelopment(
        arguments: [String],
        environment: [String: String]
    ) -> Result<AxolotyServeCommand, AxolotyServeError> {
        let flags: ParsedFlags
        switch parseFlags(arguments) {
        case .success(let parsed): flags = parsed
        case .failure(let err): return .failure(err)
        }

        for key in flags.values.keys {
            guard Self.devKnownOptions.contains(key) else {
                return .failure(.unknownOption(key))
            }
        }
        for (key, value) in flags.values {
            if value.isEmpty {
                return .failure(.missingValue(key))
            }
        }

        let namespace = flags.values["namespace"]
            ?? environment["AXOLOTY_NAMESPACE"]
            ?? "-"

        let mqttPort: UInt16
        switch resolvePort(flags.values["mqtt-port"], environment: nil, key: nil, default: 1883) {
        case .success(let p): mqttPort = p
        case .failure(let e): return .failure(e)
        }

        let mcpPort: UInt16
        switch resolvePort(flags.values["mcp-port"], environment: nil, key: nil, default: 8765) {
        case .success(let p): mcpPort = p
        case .failure(let e): return .failure(e)
        }

        let output: ServeOutputMode
        switch resolveOutputMode(flags.values["output"]) {
        case .success(let o): output = o
        case .failure(let e): return .failure(e)
        }

        let mqtt = MQTTServiceConfiguration(
            listenHost: "127.0.0.1",
            port: mqttPort,
            logLevel: .info,
            output: output
        )
        let mcp = MCPServiceConfiguration(
            transport: .http,
            listenHost: "127.0.0.1",
            listenPort: mcpPort,
            path: "/mcp",
            brokerHost: "127.0.0.1",
            brokerPort: mqttPort,
            namespace: namespace,
            connectTimeout: "10s",
            output: output
        )

        return .success(.development(DevelopmentServiceConfiguration(
            mqtt: mqtt,
            mcp: mcp,
            namespace: namespace,
            output: output
        )))
    }

    // MARK: - Helpers

    private func resolvePort(
        _ cliValue: String?,
        environment: [String: String]?,
        key: String?,
        default defaultValue: UInt16
    ) -> Result<UInt16, AxolotyServeError> {
        let raw = cliValue
            ?? (key.flatMap { environment?[$0] })
            ?? String(defaultValue)

        guard let port = UInt16(raw), port > 0 else {
            return .failure(.invalidPort(raw))
        }
        return .success(port)
    }

    private func resolveOutputMode(_ value: String?) -> Result<ServeOutputMode, AxolotyServeError> {
        guard let value else { return .success(.human) }
        guard let mode = ServeOutputMode(rawValue: value) else {
            return .failure(.invalidOutputMode(value))
        }
        return .success(mode)
    }

    private func resolveLogLevel(_ value: String?) -> Result<ServiceLogLevel, AxolotyServeError> {
        guard let value else { return .success(.info) }
        guard let level = ServiceLogLevel(rawValue: value) else {
            return .failure(.invalidLogLevel(value))
        }
        return .success(level)
    }

    private func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isValidConnectTimeout(_ value: String) -> Bool {
        guard let duration = parseBoundedDuration(value) else { return false }
        return duration > 0
    }

    static func connectTimeoutSeconds(_ value: String) -> Double? {
        parseBoundedDuration(value).map(Double.init)
    }

    /// Mirrors the duration syntax used by the inspector CLI without making
    /// the orchestration target depend on the product runtime target.
    private static func parseBoundedDuration(_ rawValue: String) -> Int64? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let unit = trimmed.last else { return nil }
        let amount = String(trimmed.dropLast())
        guard let number = Int64(amount), number > 0 else { return nil }
        let multiplier: Int64
        switch unit.lowercased() {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        default: return nil
        }
        let (seconds, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow, seconds <= 86_400 else { return nil }
        return seconds
    }
}
