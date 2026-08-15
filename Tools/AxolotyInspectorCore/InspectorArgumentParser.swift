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

/// A bounded, pure parser for the inspector command surface.
public struct InspectorArgumentParser: Sendable {
    /// The inspector version string.
    public static let version = "0.5.0"

    /// The help text printed for `--help` or unknown commands.
    public static let helpText = """
    Usage: axoloty-inspect <command> [options]

    Inspect live Coaty objects on an MQTT broker.

    Commands:
      catalog              Observe Advertise/Deadvertise and build an object catalogue.
      discover             Send a Discover request and collect Resolve responses.

    \(InspectorCommonOptionParser.helpText)

    Catalogue options:
      --core-type TYPE     Filter by Coaty core type.
      --object-type TYPE   Filter by full object type.
      --object-id UUID     Filter by object UUID.
      --source-id UUID     Filter by source (advertiser) UUID.
      --duration D         Observation duration (e.g. 10s, 2m, 1h; default: unlimited).
      --full               Include complete raw object JSON payload.
      --include-private-data  Include private data (requires --full).

    Discover options:
      --core-type TYPE     Select by Coaty core type.
      --object-type TYPE   Select by full object type.
      --object-id UUID     Select by object UUID.
      --timeout D          Response collection timeout (e.g. 5s; default: unlimited).

    Other:
      -h, --help           Show this help.
      -v, --version        Show the inspector version.

    Durations: <N>s (seconds), <N>m (minutes), <N>h (hours), unlimited.
    """

    /// Creates a parser.
    public init() {}

    /// Parses arguments against the provided environment defaults.
    ///
    /// - Parameters:
    ///   - arguments: The arguments after the executable name.
    ///   - environment: Environment-derived defaults for the broker connection.
    /// - Returns: A runnable configuration, help or version request, or a
    ///   structured parsing error.
    public func parse(
        _ arguments: [String],
        environment: InspectorEnvironmentValues = .defaults
    ) -> InspectorParseOutcome {
        guard !arguments.isEmpty else {
            return .error(.invalidArguments(reason: "no command specified; use --help"))
        }
        switch arguments[0] {
        case "--help", "-h": return .help
        case "--version", "-v": return .version
        case "catalog": return parseCatalog(Array(arguments.dropFirst()), environment: environment)
        case "discover": return parseDiscover(Array(arguments.dropFirst()), environment: environment)
        default: return .error(.invalidArguments(reason: "unknown command: \(arguments[0])"))
        }
    }
}

private extension InspectorArgumentParser {
    func parseCatalog(_ args: [String], environment: InspectorEnvironmentValues) -> InspectorParseOutcome {
        var common = InspectorCommonOptions(environment: environment)
        var coreType: String?
        var objectType: String?
        var objectId: String?
        var sourceId: String?
        var duration = InspectorDuration.unlimited
        var full = false
        var includePrivateData = false
        var seenSingletons = Set<String>()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch InspectorCommonOptionParser.parse(args, at: i, options: &common) {
            case let .consumed(nextIndex):
                i = nextIndex
                continue
            case let .failure(error):
                return .error(error)
            case .unrecognized:
                break
            }
            switch arg {
            case "--core-type":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--core-type requires a value")) }
                guard seenSingletons.insert("core-type").inserted else { return .error(.invalidArguments(reason: "--core-type specified more than once")) }
                coreType = value; i = next
            case "--object-type":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--object-type requires a value")) }
                guard seenSingletons.insert("object-type").inserted else { return .error(.invalidArguments(reason: "--object-type specified more than once")) }
                objectType = value; i = next
            case "--object-id":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--object-id requires a value")) }
                guard seenSingletons.insert("object-id").inserted else { return .error(.invalidArguments(reason: "--object-id specified more than once")) }
                objectId = value; i = next
            case "--source-id":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--source-id requires a value")) }
                guard seenSingletons.insert("source-id").inserted else { return .error(.invalidArguments(reason: "--source-id specified more than once")) }
                sourceId = value; i = next
            case "--duration":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--duration requires a value")) }
                guard let parsed = InspectorDuration(rawValue: value) else { return .error(.invalidConfiguration(field: "duration", reason: "invalid duration: \(value)")) }
                duration = parsed; i = next
            case "--full": full = true; i += 1
            case "--include-private-data": includePrivateData = true; i += 1
            default: return .error(.invalidArguments(reason: "unknown option: \(arg)"))
            }
        }

        guard !includePrivateData || full else {
            return .error(.invalidArguments(reason: "--include-private-data requires --full"))
        }

        guard common.output != .json || duration.value != nil else {
            return .error(.invalidArguments(
                reason: "--output json requires a finite --duration for catalog"
            ))
        }

        return .run(InspectorConfiguration(
            command: .catalog(CatalogCommand(
                duration: duration, coreType: coreType, objectType: objectType,
                objectId: objectId, sourceId: sourceId, full: full,
                includePrivateData: includePrivateData
            )),
            connection: common.connection,
            output: common.output,
            logLevel: common.logLevel.rawValue,
            passwordFromStdin: common.passwordFromStdin
        ))
    }

    func parseDiscover(_ args: [String], environment: InspectorEnvironmentValues) -> InspectorParseOutcome {
        var common = InspectorCommonOptions(environment: environment)
        var coreType: String?
        var objectType: String?
        var objectId: String?
        var timeout = InspectorDuration.unlimited
        var seenSingletons = Set<String>()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch InspectorCommonOptionParser.parse(args, at: i, options: &common) {
            case let .consumed(nextIndex):
                i = nextIndex
                continue
            case let .failure(error):
                return .error(error)
            case .unrecognized:
                break
            }
            switch arg {
            case "--core-type":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--core-type requires a value")) }
                guard seenSingletons.insert("core-type").inserted else { return .error(.invalidArguments(reason: "--core-type specified more than once")) }
                coreType = value; i = next
            case "--object-type":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--object-type requires a value")) }
                guard seenSingletons.insert("object-type").inserted else { return .error(.invalidArguments(reason: "--object-type specified more than once")) }
                objectType = value; i = next
            case "--object-id":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--object-id requires a value")) }
                guard seenSingletons.insert("object-id").inserted else { return .error(.invalidArguments(reason: "--object-id specified more than once")) }
                objectId = value; i = next
            case "--timeout":
                guard let (value, next) = consumeValue(args, at: i) else { return .error(.invalidArguments(reason: "--timeout requires a value")) }
                guard let parsed = InspectorDuration(rawValue: value) else { return .error(.invalidConfiguration(field: "timeout", reason: "invalid duration: \(value)")) }
                timeout = parsed; i = next
            default: return .error(.invalidArguments(reason: "unknown option: \(arg)"))
            }
        }

        guard coreType != nil || objectType != nil || objectId != nil else {
            return .error(.invalidArguments(reason: "discover requires at least one selector: --core-type, --object-type, or --object-id"))
        }
        return .run(InspectorConfiguration(
            command: .discover(DiscoverCommand(coreType: coreType, objectType: objectType, objectId: objectId, timeout: timeout)),
            connection: common.connection,
            output: common.output,
            logLevel: common.logLevel.rawValue,
            passwordFromStdin: common.passwordFromStdin
        ))
    }
}

private struct InspectorCommonOptions: Equatable, Sendable {
    var host: String
    var port: UInt16
    var namespace: String
    var usesTLS = false
    var username: String?
    var password: String?
    var connectTimeout = Duration.seconds(10)
    var output = InspectorOutputMode.auto
    var logLevel = InspectorLogLevel.info
    var passwordFromStdin = false

    init(environment: InspectorEnvironmentValues) {
        host = environment.host
        port = environment.port
        namespace = environment.namespace
        username = environment.username
        password = environment.password
    }

    var connection: InspectorConnectionConfiguration {
        InspectorConnectionConfiguration(
            host: host,
            port: port,
            namespace: namespace,
            usesTLS: usesTLS,
            username: username,
            password: password,
            connectTimeout: connectTimeout
        )
    }
}

private enum InspectorCommonOptionParser {
    enum ParseResult {
        case consumed(nextIndex: Int)
        case unrecognized
        case failure(InspectorError)
    }

    static let helpText = """
    Common options:
      --host HOST          Broker host (default: localhost, env: AXOLOTY_MQTT_HOST)
      --port PORT          Broker port (default: 1883, env: AXOLOTY_MQTT_PORT)
      --namespace NS       Coaty namespace (default: -, env: AXOLOTY_NAMESPACE)
      --tls                Enable TLS for the broker connection.
      --username USER      Broker username (env: AXOLOTY_MQTT_USERNAME).
      --password-stdin     Read broker password from one line of stdin.
      --connect-timeout D  Connection readiness timeout (default: 10s).
      --log-level LEVEL    Diagnostic log level: \(InspectorLogLevel.supportedValuesDescription.replacingOccurrences(of: ", ", with: "|")).
      --output MODE        Output mode: auto|human|ndjson|json (default: auto).
    """

    static func parse(
        _ args: [String],
        at index: Int,
        options: inout InspectorCommonOptions
    ) -> ParseResult {
        switch args[index] {
        case "--host":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--host requires a value"))
            }
            options.host = value
            return .consumed(nextIndex: next)
        case "--port":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--port requires a value"))
            }
            guard let port = UInt16(value), port > 0 else {
                return .failure(.invalidConfiguration(
                    field: "port",
                    reason: "must be a positive integer ≤ 65535"
                ))
            }
            options.port = port
            return .consumed(nextIndex: next)
        case "--namespace":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--namespace requires a value"))
            }
            options.namespace = value
            return .consumed(nextIndex: next)
        case "--tls":
            options.usesTLS = true
            return .consumed(nextIndex: index + 1)
        case "--username":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--username requires a value"))
            }
            options.username = value
            return .consumed(nextIndex: next)
        case "--password-stdin":
            options.passwordFromStdin = true
            options.password = nil
            return .consumed(nextIndex: index + 1)
        case "--connect-timeout":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--connect-timeout requires a value"))
            }
            guard let duration = InspectorDuration(rawValue: value) else {
                return .failure(.invalidConfiguration(
                    field: "connect-timeout",
                    reason: "invalid duration: \(value)"
                ))
            }
            options.connectTimeout = duration.value ?? .seconds(10)
            return .consumed(nextIndex: next)
        case "--log-level":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--log-level requires a value"))
            }
            guard let logLevel = InspectorLogLevel(rawValue: value) else {
                return .failure(.invalidConfiguration(
                    field: "log-level",
                    reason: "must be one of: \(InspectorLogLevel.supportedValuesDescription)"
                ))
            }
            options.logLevel = logLevel
            return .consumed(nextIndex: next)
        case "--output":
            guard let (value, next) = consumeValue(args, at: index) else {
                return .failure(.invalidArguments(reason: "--output requires a value"))
            }
            guard let output = InspectorOutputMode(rawValue: value) else {
                return .failure(.invalidConfiguration(
                    field: "output",
                    reason: "must be one of: auto, human, ndjson, json"
                ))
            }
            options.output = output
            return .consumed(nextIndex: next)
        default:
            return .unrecognized
        }
    }
}

private func consumeValue(_ args: [String], at index: Int) -> (String, Int)? {
    let valueIndex = index + 1
    guard valueIndex < args.count else { return nil }
    return (args[valueIndex], valueIndex + 1)
}
