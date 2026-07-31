// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The outcome of parsing inspector command-line arguments.
public enum InspectorParseOutcome: Equatable, Sendable {
    /// The arguments resolved to a runnable configuration.
    case run(InspectorConfiguration)
    /// The operator requested help output.
    case help
    /// The operator requested version output.
    case version
    /// Parsing failed with a structured error.
    case error(InspectorError)
}

/// A bounded, hand-rolled parser for the inspector command surface.
///
/// The parser is pure: it takes the argument array and environment values
/// and returns an ``InspectorParseOutcome`` without performing any I/O.
/// The caller is responsible for reading stdin (for `--password-stdin`)
/// and producing the final configuration before starting the session.
public struct InspectorArgumentParser: Sendable {
    /// The inspector version string.
    public static let version = "0.1.0"

    /// The help text printed for `--help` or unknown commands.
    public static let helpText = """
    Usage: axoloty-inspect <command> [options]

    Inspect live Coaty objects on an MQTT broker.

    Commands:
      catalog              Observe Advertise/Deadvertise and build an object catalogue.
      discover             Send a Discover request and collect Resolve responses.

    Connection options:
      --host HOST          Broker host (default: localhost, env: AXOLOTY_MQTT_HOST)
      --port PORT          Broker port (default: 1883, env: AXOLOTY_MQTT_PORT)
      --namespace NS       Coaty namespace (default: -, env: AXOLOTY_NAMESPACE)
      --tls                Enable TLS for the broker connection.
      --username USER      Broker username (env: AXOLOTY_MQTT_USERNAME).
      --password-stdin     Read broker password from one line of stdin.
      --connect-timeout D  Connection readiness timeout (default: 10s).
      --log-level LEVEL    Diagnostic log level: trace|debug|info|notice|warning|error.

    Catalogue options:
      --core-type TYPE     Filter by Coaty core type.
      --object-type TYPE   Filter by full object type.
      --object-id UUID     Filter by object UUID.
      --source-id UUID     Filter by source (advertiser) UUID.
      --duration D         Observation duration (e.g. 10s, 2m, 1h; default: unlimited).
      --output MODE        Output mode: auto|human|ndjson|json (default: auto).
      --full               Include complete raw object JSON payload.
      --include-private-data  Include private data (requires --full).

    Discover options:
      --core-type TYPE     Select by Coaty core type.
      --object-type TYPE   Select by full object type.
      --object-id UUID     Select by object UUID.
      --timeout D          Response collection timeout (e.g. 5s; default: unlimited).

    Other:
      -h, --help            Show this help.
      -v, --version         Show the inspector version.

    Durations: <N>s (seconds), <N>m (minutes), <N>h (hours), unlimited.
    """

    /// Creates a parser.
    public init() {}

    /// Parses arguments against the provided environment defaults.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after the executable name.
    ///   - environment: Environment-derived defaults for broker connection.
    /// - Returns: The parse outcome — a configuration, help, version, or error.
    public func parse(
        _ arguments: [String],
        environment: InspectorEnvironmentValues = .defaults
    ) -> InspectorParseOutcome {
        guard !arguments.isEmpty else {
            return .error(.invalidArguments(reason: "no command specified; use --help"))
        }

        switch arguments[0] {
        case "--help", "-h":
            return .help
        case "--version", "-v":
            return .version
        case "catalog":
            return parseCatalog(Array(arguments.dropFirst()), environment: environment)
        case "discover":
            return .error(.invalidArguments(reason: "discover is not yet supported"))
        default:
            return .error(.invalidArguments(reason: "unknown command: \(arguments[0])"))
        }
    }
}

// MARK: - Catalog parsing

private extension InspectorArgumentParser {
    func parseCatalog(
        _ args: [String],
        environment: InspectorEnvironmentValues
    ) -> InspectorParseOutcome {
        var host = environment.host
        var port = environment.port
        var namespace = environment.namespace
        var usesTLS = false
        var username = environment.username
        var password = environment.password
        var passwordFromStdin = false
        var connectTimeout = Duration.seconds(10)
        var logLevel = "info"
        var coreType: String?
        var objectType: String?
        var objectId: String?
        var sourceId: String?
        var duration = InspectorDuration.unlimited
        var output = InspectorOutputMode.auto
        var full = false
        var includePrivateData = false

        var seenSingletons = Set<String>()

        var i = 0
        while i < args.count {
            let arg = args[i]

            switch arg {
            case "--host":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--host requires a value"))
                }
                host = value
                i = next
            case "--port":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--port requires a value"))
                }
                guard let parsedPort = UInt16(value), parsedPort > 0 else {
                    return .error(.invalidConfiguration(field: "port", reason: "must be a positive integer ≤ 65535"))
                }
                port = parsedPort
                i = next
            case "--namespace":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--namespace requires a value"))
                }
                namespace = value
                i = next
            case "--tls":
                usesTLS = true
                i += 1
            case "--username":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--username requires a value"))
                }
                username = value
                i = next
            case "--password-stdin":
                passwordFromStdin = true
                password = nil
                i += 1
            case "--connect-timeout":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--connect-timeout requires a value"))
                }
                guard let parsed = InspectorDuration(rawValue: value) else {
                    return .error(.invalidConfiguration(field: "connect-timeout", reason: "invalid duration: \(value)"))
                }
                connectTimeout = parsed.value ?? .seconds(10)
                i = next
            case "--log-level":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--log-level requires a value"))
                }
                logLevel = value
                i = next
            case "--core-type":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--core-type requires a value"))
                }
                if seenSingletons.contains("core-type") {
                    return .error(.invalidArguments(reason: "--core-type specified more than once"))
                }
                seenSingletons.insert("core-type")
                coreType = value
                i = next
            case "--object-type":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--object-type requires a value"))
                }
                if seenSingletons.contains("object-type") {
                    return .error(.invalidArguments(reason: "--object-type specified more than once"))
                }
                seenSingletons.insert("object-type")
                objectType = value
                i = next
            case "--object-id":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--object-id requires a value"))
                }
                if seenSingletons.contains("object-id") {
                    return .error(.invalidArguments(reason: "--object-id specified more than once"))
                }
                seenSingletons.insert("object-id")
                objectId = value
                i = next
            case "--source-id":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--source-id requires a value"))
                }
                if seenSingletons.contains("source-id") {
                    return .error(.invalidArguments(reason: "--source-id specified more than once"))
                }
                seenSingletons.insert("source-id")
                sourceId = value
                i = next
            case "--duration":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--duration requires a value"))
                }
                guard let parsed = InspectorDuration(rawValue: value) else {
                    return .error(.invalidConfiguration(field: "duration", reason: "invalid duration: \(value)"))
                }
                duration = parsed
                i = next
            case "--output":
                guard let (value, next) = consumeValue(args, at: i) else {
                    return .error(.invalidArguments(reason: "--output requires a value"))
                }
                guard let parsed = InspectorOutputMode(rawValue: value) else {
                    return .error(.invalidConfiguration(field: "output", reason: "must be one of: auto, human, ndjson, json"))
                }
                output = parsed
                i = next
            case "--full":
                full = true
                i += 1
            case "--include-private-data":
                includePrivateData = true
                i += 1
            default:
                return .error(.invalidArguments(reason: "unknown option: \(arg)"))
            }
        }

        let connection = InspectorConnectionConfiguration(
            host: host,
            port: port,
            namespace: namespace,
            usesTLS: usesTLS,
            username: username,
            password: password,
            connectTimeout: connectTimeout
        )
        let command = InspectorCommand.catalog(CatalogCommand(
            duration: duration,
            coreType: coreType,
            objectType: objectType,
            objectId: objectId,
            sourceId: sourceId,
            full: full,
            includePrivateData: includePrivateData
        ))
        let config = InspectorConfiguration(
            command: command,
            connection: connection,
            output: output,
            logLevel: logLevel,
            passwordFromStdin: passwordFromStdin
        )
        return .run(config)
    }
}

// MARK: - Helpers

private func consumeValue(_ args: [String], at index: Int) -> (String, Int)? {
    let valueIndex = index + 1
    guard valueIndex < args.count else {
        return nil
    }
    return (args[valueIndex], valueIndex + 1)
}
