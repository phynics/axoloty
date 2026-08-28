// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorArgumentParserTests {
    // MARK: - Help and version

    @Test
    func helpFlagReturnsHelp() {
        let outcome = InspectorArgumentParser().parse(["--help"])
        #expect(outcome == .help)
    }

    @Test
    func shortHelpFlagReturnsHelp() {
        let outcome = InspectorArgumentParser().parse(["-h"])
        #expect(outcome == .help)
    }

    @Test
    func versionFlagReturnsVersion() {
        let outcome = InspectorArgumentParser().parse(["--version"])
        #expect(outcome == .version)
        #expect(InspectorArgumentParser.version == "0.6.2")
    }

    @Test
    func shortVersionFlagReturnsVersion() {
        let outcome = InspectorArgumentParser().parse(["-v"])
        #expect(outcome == .version)
    }

    // MARK: - Empty and unknown

    @Test
    func emptyArgumentsReturnsError() {
        let outcome = InspectorArgumentParser().parse([])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "no command specified; use --help"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func unknownCommandReturnsError() {
        let outcome = InspectorArgumentParser().parse(["bogus"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "unknown command: bogus"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func unknownOptionReturnsError() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--bogus"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "unknown option: --bogus"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    // MARK: - Discover parsing

    @Test
    func discoverRequiresAtLeastOneSelector() {
        let outcome = InspectorArgumentParser().parse(["discover"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(
                reason: "discover requires at least one selector: --core-type, --object-type, or --object-id"
            ))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func discoverWithInspectorCoreType() {
        let outcome = InspectorArgumentParser().parse(["discover", "--core-type", "Identity"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .discover(let cmd) = config.command else {
            Issue.record("Expected discover command")
            return
        }
        #expect(cmd.coreType == "Identity")
        #expect(cmd.objectType == nil)
        #expect(cmd.objectId == nil)
        #expect(cmd.timeout == .unlimited)
    }

    @Test
    func discoverWithObjectType() {
        let outcome = InspectorArgumentParser().parse(["discover", "--object-type", "com.example.Sensor"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .discover(let cmd) = config.command else {
            Issue.record("Expected discover command")
            return
        }
        #expect(cmd.coreType == nil)
        #expect(cmd.objectType == "com.example.Sensor")
    }

    @Test
    func discoverWithObjectId() {
        let outcome = InspectorArgumentParser().parse(["discover", "--object-id", "abc-123"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .discover(let cmd) = config.command else {
            Issue.record("Expected discover command")
            return
        }
        #expect(cmd.objectId == "abc-123")
    }

    @Test
    func discoverWithTimeout() {
        let outcome = InspectorArgumentParser().parse(["discover", "--core-type", "Identity", "--timeout", "5s"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .discover(let cmd) = config.command else {
            Issue.record("Expected discover command")
            return
        }
        #expect(cmd.timeout.value == .seconds(5))
    }

    @Test
    func discoverWithConnectionOptions() {
        let outcome = InspectorArgumentParser().parse([
            "discover", "--core-type", "Identity",
            "--host", "broker.local", "--port", "8883", "--namespace", "test-ns",
        ])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.host == "broker.local")
        #expect(config.connection.port == 8883)
        #expect(config.connection.namespace == "test-ns")
    }

    @Test
    func commonOptionsHaveSameContractAcrossCommands() {
        let commonOptions = [
            "--host", "broker.local",
            "--port", "8883",
            "--namespace", "test-ns",
            "--connect-timeout", "5s",
            "--output", "json",
            "--log-level", "debug",
        ]

        for command in [
            ["catalog", "--duration", "1s"],
            ["discover", "--core-type", "Identity"],
        ] {
            let outcome = InspectorArgumentParser().parse(command + commonOptions)
            guard case let .run(config) = outcome else {
                Issue.record("Expected \(command[0]) to accept the common inspector options")
                continue
            }

            #expect(config.connection.host == "broker.local")
            #expect(config.connection.port == 8883)
            #expect(config.connection.namespace == "test-ns")
            #expect(config.connection.connectTimeout == .seconds(5))
            #expect(config.output == .json)
            #expect(config.logLevel == "debug")
        }
    }

    @Test
    func everySharedOptionParsesIdenticallyForCatalogAndDiscover() {
        let sharedOptions = [
            "--host", "broker.local",
            "--port", "8883",
            "--namespace", "test-ns",
            "--tls",
            "--username", "operator",
            "--password-stdin",
            "--connect-timeout", "5s",
            "--log-level", "debug",
            "--output", "ndjson",
        ]

        let catalog = InspectorArgumentParser().parse(["catalog"] + sharedOptions)
        let discover = InspectorArgumentParser().parse(["discover", "--core-type", "Identity"] + sharedOptions)

        guard case let .run(catalogConfig) = catalog,
              case let .run(discoverConfig) = discover else {
            Issue.record("Expected both commands to accept every shared option")
            return
        }

        #expect(catalogConfig.connection == discoverConfig.connection)
        #expect(catalogConfig.output == discoverConfig.output)
        #expect(catalogConfig.logLevel == discoverConfig.logLevel)
        #expect(catalogConfig.passwordFromStdin == discoverConfig.passwordFromStdin)
    }

    @Test
    func helpRendersCompleteSectionsInContractOrder() {
        let expected = """
        Usage: axoloty-inspect <command> [options]

        Inspect live Coaty objects on an MQTT broker.

        Commands:
          catalog              Observe Advertise/Deadvertise and build an object catalogue.
          discover             Send a Discover request and collect Resolve responses.

        Common options:
          --host HOST          Broker host (default: localhost, env: AXOLOTY_MQTT_HOST)
          --port PORT          Broker port (default: 1883, env: AXOLOTY_MQTT_PORT)
          --namespace NS       Coaty namespace (default: -, env: AXOLOTY_NAMESPACE)
          --tls                Enable TLS for the broker connection.
          --username USER      Broker username (env: AXOLOTY_MQTT_USERNAME).
          --password-stdin     Read broker password from one line of stdin.
          --connect-timeout D  Connection readiness timeout (default: 10s).
          --log-level LEVEL    Diagnostic log level: trace|debug|info|notice|warning|error.
          --output MODE        Output mode: auto|human|ndjson|json (default: auto).

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

        #expect(InspectorArgumentParser.helpText == expected)
    }

    @Test
    func commonOptionFailuresMatchAcrossCommands() {
        let commands = [
            ["catalog"],
            ["discover", "--core-type", "Identity"],
        ]
        let cases: [([String], InspectorError)] = [
            (["--host"], .invalidArguments(reason: "--host requires a value")),
            (["--port", "0"], .invalidConfiguration(
                field: "port",
                reason: "must be a positive integer ≤ 65535"
            )),
            (["--connect-timeout", "0s"], .invalidConfiguration(
                field: "connect-timeout",
                reason: "invalid duration: 0s"
            )),
            (["--output", "xml"], .invalidConfiguration(
                field: "output",
                reason: "must be one of: auto, human, ndjson, json"
            )),
            (["--log-level", "critical"], .invalidConfiguration(
                field: "log-level",
                reason: "must be one of: trace, debug, info, notice, warning, error"
            )),
        ]

        for command in commands {
            for (options, expectedError) in cases {
                let outcome = InspectorArgumentParser().parse(command + options)
                #expect(outcome == .error(expectedError))
            }
        }
    }

    @Test
    func repeatedCommonOptionsUseLastValueAcrossCommands() {
        for command in [
            ["catalog", "--duration", "1s"],
            ["discover", "--core-type", "Identity"],
        ] {
            let outcome = InspectorArgumentParser().parse(command + [
                "--host", "first.example",
                "--host", "last.example",
                "--output", "human",
                "--output", "json",
            ])
            guard case let .run(config) = outcome else {
                Issue.record("Expected repeated common options to parse for \(command[0])")
                continue
            }
            #expect(config.connection.host == "last.example")
            #expect(config.output == .json)
        }
    }

    @Test
    func cliCommonOptionsOverrideEnvironmentAcrossCommands() {
        let environment = InspectorEnvironmentValues(
            host: "environment.example",
            port: 1883,
            username: "environment-user",
            password: "environment-password",
            namespace: "environment-namespace"
        )

        for command in [
            ["catalog"],
            ["discover", "--core-type", "Identity"],
        ] {
            let outcome = InspectorArgumentParser().parse(command + [
                "--host", "cli.example",
                "--port", "8883",
                "--namespace", "cli-namespace",
                "--username", "cli-user",
                "--password-stdin",
            ], environment: environment)
            guard case let .run(config) = outcome else {
                Issue.record("Expected CLI precedence for \(command[0])")
                continue
            }
            #expect(config.connection.host == "cli.example")
            #expect(config.connection.port == 8883)
            #expect(config.connection.namespace == "cli-namespace")
            #expect(config.connection.username == "cli-user")
            #expect(config.connection.password == nil)
            #expect(config.passwordFromStdin)
        }
    }

    @Test
    func sharedOptionsCanAppearBeforeBetweenAndAfterCatalogOptions() {
        let outcome = InspectorArgumentParser().parse([
            "catalog",
            "--host", "before.example",
            "--core-type", "Identity",
            "--output", "json",
            "--duration", "1s",
            "--source-id", "source-1",
            "--log-level", "debug",
        ])
        guard case let .run(config) = outcome,
              case let .catalog(command) = config.command else {
            Issue.record("Expected interleaved catalog options to parse")
            return
        }
        #expect(config.connection.host == "before.example")
        #expect(config.output == .json)
        #expect(config.logLevel == "debug")
        #expect(command.coreType == "Identity")
        #expect(command.sourceId == "source-1")
    }

    @Test
    func sharedOptionsCanAppearBeforeBetweenAndAfterDiscoverOptions() {
        let outcome = InspectorArgumentParser().parse([
            "discover",
            "--host", "before.example",
            "--core-type", "Identity",
            "--output", "ndjson",
            "--object-id", "object-1",
            "--log-level", "trace",
        ])
        guard case let .run(config) = outcome,
              case let .discover(command) = config.command else {
            Issue.record("Expected interleaved discover options to parse")
            return
        }
        #expect(config.connection.host == "before.example")
        #expect(config.output == .ndjson)
        #expect(config.logLevel == "trace")
        #expect(command.coreType == "Identity")
        #expect(command.objectId == "object-1")
    }

    @Test
    func catalogOptionBindsCommonLookingValueBeforeParsingNextToken() {
        let outcome = InspectorArgumentParser().parse([
            "catalog", "--object-type", "--host", "broker.local",
        ])
        #expect(outcome == .error(.invalidArguments(reason: "unknown option: broker.local")))
    }

    @Test
    func discoverOptionBindsCommonLookingValueBeforeParsingNextToken() {
        let outcome = InspectorArgumentParser().parse([
            "discover", "--object-id", "--output", "json",
        ])
        #expect(outcome == .error(.invalidArguments(reason: "unknown option: json")))
    }

    @Test
    func discoverRejectsUnknownOption() {
        let outcome = InspectorArgumentParser().parse(["discover", "--core-type", "Identity", "--duration", "5s"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "unknown option: --duration"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    // MARK: - Catalog parsing

    @Test
    func catalogWithDefaults() {
        let outcome = InspectorArgumentParser().parse(["catalog"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .catalog(let cmd) = config.command else {
            Issue.record("Expected catalog command")
            return
        }
        #expect(cmd.duration == .unlimited)
        #expect(cmd.coreType == nil)
        #expect(cmd.objectType == nil)
        #expect(cmd.objectId == nil)
        #expect(cmd.sourceId == nil)
        #expect(cmd.full == false)
        #expect(cmd.includePrivateData == false)
        #expect(config.output == .auto)
        #expect(config.connection.host == "localhost")
        #expect(config.connection.port == 1883)
        #expect(config.connection.namespace == "-")
        #expect(config.connection.usesTLS == false)
        #expect(config.connection.username == nil)
        #expect(config.connection.password == nil)
        #expect(config.passwordFromStdin == false)
    }

    @Test
    func catalogWithHostAndPort() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--host", "broker.local", "--port", "8883"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.host == "broker.local")
        #expect(config.connection.port == 8883)
    }

    @Test
    func catalogWithTLS() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--tls"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.usesTLS == true)
    }

    @Test
    func catalogWithUsernameAndPasswordStdin() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--username", "operator", "--password-stdin"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.username == "operator")
        #expect(config.connection.password == nil)
        #expect(config.passwordFromStdin == true)
    }

    @Test
    func catalogWithNamespace() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--namespace", "test-ns"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.namespace == "test-ns")
    }

    @Test
    func catalogWithDuration() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--duration", "10s"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .catalog(let cmd) = config.command else {
            Issue.record("Expected catalog command")
            return
        }
        #expect(cmd.duration.value == .seconds(10))
    }

    @Test
    func catalogWithOutputMode() {
        for mode in ["auto", "human", "ndjson", "json"] {
            var arguments = ["catalog", "--output", mode]
            if mode == "json" { arguments += ["--duration", "1s"] }
            let outcome = InspectorArgumentParser().parse(arguments)
            guard case let .run(config) = outcome else {
                Issue.record("Expected run outcome for --output \(mode)")
                return
            }
            #expect(config.output.rawValue == mode)
        }
    }

    @Test
    func catalogJSONRequiresFiniteDuration() {
        for duration in ["unlimited", nil] {
            var arguments = ["catalog", "--output", "json"]
            if let duration {
                arguments += ["--duration", duration]
            }
            #expect(InspectorArgumentParser().parse(arguments) == .error(.invalidArguments(
                reason: "--output json requires a finite --duration for catalog"
            )))
        }
    }

    @Test
    func catalogJSONAcceptsFiniteDuration() {
        let outcome = InspectorArgumentParser().parse([
            "catalog", "--output", "json", "--duration", "1s",
        ])
        guard case let .run(config) = outcome else {
            Issue.record("Expected finite JSON catalog to parse")
            return
        }
        #expect(config.output == .json)
        guard case let .catalog(command) = config.command else {
            Issue.record("Expected catalog command")
            return
        }
        #expect(command.duration.value == .seconds(1))
    }

    @Test
    func catalogWithFullAndPrivateData() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--full", "--include-private-data"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .catalog(let cmd) = config.command else {
            Issue.record("Expected catalog command")
            return
        }
        #expect(cmd.full == true)
        #expect(cmd.includePrivateData == true)
    }

    @Test
    func catalogRejectsPrivateDataWithoutFull() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--include-private-data"])
        #expect(outcome == .error(.invalidArguments(
            reason: "--include-private-data requires --full"
        )))
    }

    @Test
    func catalogWithAllFilters() {
        let outcome = InspectorArgumentParser().parse([
            "catalog",
            "--core-type", "Identity",
            "--object-type", "com.example.Sensor",
            "--object-id", "abc-123",
            "--source-id", "def-456",
        ])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        guard case .catalog(let cmd) = config.command else {
            Issue.record("Expected catalog command")
            return
        }
        #expect(cmd.coreType == "Identity")
        #expect(cmd.objectType == "com.example.Sensor")
        #expect(cmd.objectId == "abc-123")
        #expect(cmd.sourceId == "def-456")
    }

    @Test
    func catalogWithConnectTimeout() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--connect-timeout", "5s"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.connectTimeout == .seconds(5))
    }

    @Test
    func catalogWithLogLevel() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--log-level", "debug"])
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.logLevel == "debug")
    }

    @Test
    func everySupportedLogLevelParses() {
        for level in InspectorLogLevel.allCases {
            let outcome = InspectorArgumentParser().parse(["catalog", "--log-level", level.rawValue])
            guard case let .run(config) = outcome else {
                Issue.record("Expected --log-level \(level.rawValue) to parse")
                continue
            }
            #expect(config.logLevel == level.rawValue)
        }
    }

    // MARK: - Missing values

    @Test
    func missingHostValue() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--host"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--host requires a value"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func missingPortValue() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--port"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--port requires a value"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func missingDurationValue() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--duration"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--duration requires a value"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func missingOutputValue() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--output"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--output requires a value"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func missingLogLevelValue() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--log-level"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--log-level requires a value"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    // MARK: - Invalid values

    @Test
    func invalidPortZero() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--port", "0"])
        if case let .error(error) = outcome {
            #expect(error == .invalidConfiguration(field: "port", reason: "must be a positive integer ≤ 65535"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func invalidPortNonNumeric() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--port", "abc"])
        if case let .error(error) = outcome {
            #expect(error == .invalidConfiguration(field: "port", reason: "must be a positive integer ≤ 65535"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func invalidPortOverflow() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--port", "99999"])
        if case let .error(error) = outcome {
            #expect(error == .invalidConfiguration(field: "port", reason: "must be a positive integer ≤ 65535"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func invalidDuration() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--duration", "0s"])
        if case let .error(error) = outcome {
            #expect(error == .invalidConfiguration(field: "duration", reason: "invalid duration: 0s"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func invalidOutputMode() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--output", "xml"])
        if case let .error(error) = outcome {
            #expect(error == .invalidConfiguration(field: "output", reason: "must be one of: auto, human, ndjson, json"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func invalidLogLevelUsesStructuredConfigurationError() {
        let invalidValues = ["critical", "verbose"]
        let expectedError = InspectorError.invalidConfiguration(
            field: "log-level",
            reason: "must be one of: trace, debug, info, notice, warning, error"
        )

        for value in invalidValues {
            let outcome = InspectorArgumentParser().parse(["catalog", "--log-level", value])
            #expect(outcome == .error(expectedError))
        }
    }

    @Test
    func logLevelIsCaseSensitiveAndDoesNotTrimWhitespace() {
        for value in ["TRACE", "Info", " warning "] {
            let outcome = InspectorArgumentParser().parse(["catalog", "--log-level", value])
            #expect(outcome == .error(.invalidConfiguration(
                field: "log-level",
                reason: "must be one of: trace, debug, info, notice, warning, error"
            )))
        }
    }

    // MARK: - Duplicate singleton options

    @Test
    func duplicateInspectorCoreTypeRejected() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--core-type", "Identity", "--core-type", "Sensor"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--core-type specified more than once"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func duplicateObjectTypeRejected() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--object-type", "a", "--object-type", "b"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--object-type specified more than once"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func duplicateObjectIdRejected() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--object-id", "a", "--object-id", "b"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--object-id specified more than once"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    @Test
    func duplicateSourceIdRejected() {
        let outcome = InspectorArgumentParser().parse(["catalog", "--source-id", "a", "--source-id", "b"])
        if case let .error(error) = outcome {
            #expect(error == .invalidArguments(reason: "--source-id specified more than once"))
        } else {
            Issue.record("Expected error outcome")
        }
    }

    // MARK: - Environment fallback

    @Test
    func environmentFallbackForHost() {
        let env = InspectorEnvironmentValues(host: "env-broker", port: 1883, username: nil, password: nil, namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.host == "env-broker")
    }

    @Test
    func environmentFallbackForPort() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 8883, username: nil, password: nil, namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.port == 8883)
    }

    @Test
    func environmentFallbackForNamespace() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 1883, username: nil, password: nil, namespace: "env-ns")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.namespace == "env-ns")
    }

    @Test
    func environmentFallbackForUsername() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 1883, username: "env-user", password: nil, namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.username == "env-user")
    }

    @Test
    func environmentFallbackForPassword() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 1883, username: nil, password: "env-pass", namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.password == "env-pass")
        #expect(config.passwordFromStdin == false)
    }

    @Test
    func environmentFromDictionary() {
        let env = InspectorEnvironmentValues(environment: [
            "AXOLOTY_MQTT_HOST": "dict-broker",
            "AXOLOTY_MQTT_PORT": "9883",
            "AXOLOTY_MQTT_USERNAME": "dict-user",
            "AXOLOTY_NAMESPACE": "dict-ns",
        ])
        #expect(env.host == "dict-broker")
        #expect(env.port == 9883)
        #expect(env.username == "dict-user")
        #expect(env.namespace == "dict-ns")
    }

    @Test
    func environmentDictionaryFallsBackToDefaults() {
        let env = InspectorEnvironmentValues(environment: [:])
        #expect(env.host == "localhost")
        #expect(env.port == 1883)
        #expect(env.namespace == "-")
        #expect(env.username == nil)
        #expect(env.password == nil)
    }

    // MARK: - CLI overrides environment

    @Test
    func cliOverridesEnvironmentHost() {
        let env = InspectorEnvironmentValues(host: "env-broker", port: 1883, username: nil, password: nil, namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog", "--host", "cli-broker"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.host == "cli-broker")
    }

    @Test
    func cliOverridesEnvironmentPort() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 8883, username: nil, password: nil, namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog", "--port", "1883"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.port == 1883)
    }

    // MARK: - Password redaction

    @Test
    func passwordNeverInConfigurationDescription() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 1883, username: "user", password: "secret-pass", namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        let description = String(describing: config)
        #expect(!description.contains("secret-pass"))
        #expect(description.contains("password=***"))
    }

    @Test
    func passwordStdinClearsEnvPassword() {
        let env = InspectorEnvironmentValues(host: "localhost", port: 1883, username: nil, password: "env-pass", namespace: "-")
        let outcome = InspectorArgumentParser().parse(["catalog", "--password-stdin"], environment: env)
        guard case let .run(config) = outcome else {
            Issue.record("Expected run outcome")
            return
        }
        #expect(config.connection.password == nil)
        #expect(config.passwordFromStdin == true)
    }
}
