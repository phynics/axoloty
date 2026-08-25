// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The outcome status of a hardware check.
public enum AxolotyHardwareStatus: String, Codable, Equatable, Sendable {
    /// The check was successful.
    case passed
    /// The device was absent and the check was not run.
    case skipped
    /// The device was present but the check failed.
    case failed
}

/// A structured result from an embedded hardware check.
public struct AxolotyHardwareOutcome: Codable, Equatable, Sendable {
    /// The check outcome.
    public let status: AxolotyHardwareStatus
    /// The selected device path.
    public let device: String
    /// The reason for the outcome.
    public let reason: String

    /// Creates a hardware outcome.
    public init(status: AxolotyHardwareStatus, device: String, reason: String) {
        self.status = status
        self.device = device
        self.reason = reason
    }
}

/// The filesystem boundary used by hardware checks.
public protocol AxolotyFileSystem: Sendable {
    /// Returns whether a path exists.
    func exists(atPath path: String) -> Bool
}

private struct FoundationFileSystem: AxolotyFileSystem {
    init() {}
    func exists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

/// Parses the stable command surface of the ``axoloty-tool`` executable.
// swiftlint:disable type_body_length
public struct AxolotyCommandDispatcher: Sendable {
    private let executableName: String
    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let integrationRunner: any AxolotyIntegrationRunning
    private let deviceLeaseManager: any AxolotyDeviceLeasing
    private let fileSystem: any AxolotyFileSystem
    private let environment: [String: String]
    private let processRunnerFactory: @Sendable () -> any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let tempDirProvider: any AxolotyTempDirectoryProvider
    private let timingRunner: AxolotyTimingRunner
    private let repositoryRoot: URL
    private let installSignalHandler: Bool
    private let cancellation: AxolotyCommandCancellation
    private let outputMode: AxolotyCommandOutputMode

    /// Creates a command dispatcher.
    ///
    /// - Parameters:
    ///   - executableName: The name used in version output and help text (default: `axoloty-tool`).
    ///   - commandRunner: The process runner for executing check commands. The default runner uses
    ///     the supplied `environment` snapshot for execution-context validation.
    ///   - integrationRunner: The integration test runner for broker-backed tests.
    ///   - deviceLeaseManager: The device lease manager for hardware checks.
    ///   - fileSystem: The filesystem boundary for existence checks.
    ///   - environment: The environment variable map used by command parsing and context validation.
    ///   - processRunnerFactory: A factory for process runners used by managed service commands.
    ///   - portProbe: The TCP probe for service readiness checks.
    ///   - tempDirProvider: The temporary directory provider for service configs.
    ///   - timingRunner: The runner for explicit hardware-free timing evidence.
    ///   - repositoryRoot: The repository checkout used by authority validation; defaults to the current directory.
    ///   - installSignalHandler: Whether the dispatcher installs signal handling.
    ///   - cancellation: Optional shared cancellation state for this invocation.
    public init(
        executableName: String = "axoloty-tool",
        commandRunner: any AxolotyCheckCommandRunning = FoundationCommandRunner(),
        integrationRunner: (any AxolotyIntegrationRunning)? = nil,
        deviceLeaseManager: any AxolotyDeviceLeasing = FoundationDeviceLeaseManager(),
        fileSystem: (any AxolotyFileSystem)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processRunnerFactory: (@Sendable () -> any AxolotyManagedProcessRunning)? = nil,
        portProbe: (any AxolotyServiceProbing)? = nil,
        tempDirProvider: (any AxolotyTempDirectoryProvider)? = nil,
        timingRunner: AxolotyTimingRunner? = nil,
        repositoryRoot: URL? = nil,
        installSignalHandler: Bool = true,
        cancellation: AxolotyCommandCancellation? = nil
    ) {
        let contextValidator = AxolotyExecutionContextValidator(environment: environment)
        let runnerConfiguration = AxolotyCommandRunnerConfiguration.from(environment: environment)
        let invocationCancellation = cancellation ?? AxolotyCommandCancellation()
        let commandRunner: any AxolotyCheckCommandRunning = commandRunner is FoundationCommandRunner
            ? FoundationCommandRunner(
                contextValidator: contextValidator,
                environment: environment,
                cancellation: invocationCancellation
            )
            : commandRunner
        self.executableName = executableName
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.integrationRunner = integrationRunner ?? FoundationIntegrationRunner(
            commandRunner: commandRunner,
            contextValidator: contextValidator
        )
        self.deviceLeaseManager = deviceLeaseManager
        self.fileSystem = fileSystem ?? FoundationFileSystem()
        self.environment = environment
        self.processRunnerFactory = processRunnerFactory ?? { FoundationProcessRunner() }
        self.portProbe = portProbe ?? FoundationServiceProbe()
        self.tempDirProvider = tempDirProvider ?? FoundationTempDirectoryProvider()
        self.timingRunner = timingRunner ?? AxolotyTimingRunner(
            commandRunner: commandRunner,
            environment: environment
        )
        self.repositoryRoot = (repositoryRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        self.installSignalHandler = installSignalHandler && runnerConfiguration.installSignalHandler
        self.cancellation = invocationCancellation
        outputMode = runnerConfiguration.outputMode
    }

    /// Resolves command-line arguments to their externally visible result.
    ///
    /// - Parameter arguments: Arguments after the executable name.
    /// - Returns: Text streams and exit status for the requested command.
    public func run(arguments: [String]) -> AxolotyCommandResult {
        let signalLease = installSignalHandler
            ? AxolotySignalMultiplexer.shared.acquire { [cancellation] in cancellation.cancel() }
            : nil
        defer { signalLease?.cancel() }
        if arguments.first == "serve" {
            return serveResult(arguments: Array(arguments.dropFirst()))
        }
        if arguments.count >= 2, arguments[0] == "measure", arguments[1] == "timing" {
            return timingResult(arguments: Array(arguments.dropFirst(2)))
        }
        if arguments.first == "repository", arguments.dropFirst().first == "validate" {
            return repositoryAuthorityResult(arguments: Array(arguments.dropFirst(2)))
        }
        if arguments.count == 4, arguments[0] == "hardware", ["check", "require"].contains(arguments[1]), arguments[2] == "--device" {
            return hardwareResult(required: arguments[1] == "require", device: arguments[3])
        }
        if arguments.count == 3, arguments[0] == "wire", arguments[1] == "verify" {
            return wireBundleResult(path: arguments[2])
        }
        if arguments.count == 3, arguments[0] == "test-one", arguments[1] == "--filter" {
            return testOneResult(filter: arguments[2])
        }
        if arguments.count == 2, arguments[0] == "test-tier" {
            return testTierResult(tier: arguments[1], ci: false)
        }
        if arguments.count == 3, arguments[0] == "test-tier", arguments[1] == "--ci" {
            return testTierResult(tier: arguments[2], ci: true)
        }
        if arguments.count == 2, arguments[0] == "explain" {
            return explainResult(tier: arguments[1], ci: false)
        }
        if arguments.count == 3, arguments[0] == "explain", arguments[1] == "--ci" {
            return explainResult(tier: arguments[2], ci: true)
        }
        return switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            AxolotyCommandResult(standardOutput: Self.usage(executableName: executableName))
        case ["version"], ["--version"]:
            AxolotyCommandResult(standardOutput: "\(executableName) \(Self.version)")
        case ["check", "--plan"]:
            planResult(environment: environment)
        case ["check"]:
            checkResult()
        case ["verify"]:
            verifyResult(ci: false)
        case ["verify", "--ci"]:
            verifyResult(ci: true)
        case ["test-one"]:
            testOneResult(filter: environment["FILTER"] ?? "")
        case ["test-tier"]:
            testTierResult(tier: environment["TIER"] ?? "", ci: false)
        case ["explain"]:
            explainResult(tier: environment["TIER"] ?? "", ci: false)
        case ["build"]:
            checkResult(requested: ["build"])
        case ["test", "offline"]:
            checkResult()
        case ["test", "tooling"]:
            checkResult(requested: ["test-tooling"])
        case ["test", "integration"]:
            integrationResult()
        case ["wire", "verify"]:
            checkResult(requested: ["test-wire"])
        case ["wire", "capture"]:
            execute(plan: AxolotyCheckPlan.wireCapture(environment: environment))
        case ["embedded", "build"]:
            checkResult(requested: ["embedded-build"])
        case ["embedded", "doctor"]:
            checkResult(requested: ["embedded-toolchain"])
        case ["embedded", "verify"]:
            checkResult(requested: ["embedded-linker"])
        case ["release", "fixture-bundle"]:
            fixtureBundleResult()
        case ["release", "checkpoint"]:
            checkpointResult(hardware: false)
        case ["release", "checkpoint-hardware"]:
            checkpointResult(hardware: true)
        case ["hardware", "check"]:
            hardwareResult(required: false, device: nil)
        case ["hardware", "require"]:
            hardwareResult(required: true, device: nil)
        default:
            AxolotyCommandResult(
                standardError: "error: unsupported \(executableName) command\n\n\(Self.usage(executableName: executableName))\n",
                exitCode: 64
            )
        }
    }

    private static let version = "0.5.1"

    private static func manifestDiagnostic(_ error: Error) -> String {
        if let manifestError = error as? AxolotyCanonicalTestManifestError {
            return manifestError.userFriendlyMessage
        }
        return error.localizedDescription
    }

    private static let usage = """
    Usage: axoloty-tool <command>

    Axoloty's typed build and test orchestration CLI.

    Commands:
      help, --help, -h     Show this help.
      version, --version   Show the CLI version.
      check --plan         Print the initial offline check plan as JSON.
      check                Run the initial offline check plan and print JSON.
      verify [--ci]        Run the canonical ordinary or CI verification plan.
      test-one --filter F  Run one bounded Swift suite/test filter.
      test-tier TIER       Run one canonical test tier.
      explain TIER          Print its command graph and execution policies.
      build                Build the host package and its prerequisites.
      test offline         Run the same offline plan as check.
      test tooling         Run offline developer-tool tests and prerequisites.
      test integration     Deprecated; no canonical broker-backed tier is declared.
      wire verify [BUNDLE] Verify fixtures and an optional bundle without MQTT.
      wire capture         Run live MQTT captures with pinned reference agents.
      embedded build       Cross-compile the ESP32-C6 firmware on Linux.
      embedded doctor      Verify the container's ESP-IDF build environment.
      embedded verify      Build and verify the ESP32-C6 linker contract.
      hardware check       Run or skip the sporadic hardware smoke check.
      hardware require     Require an attached device and run its smoke check.
      release fixture-bundle  Bundle committed wire fixtures offline (not fresh wire evidence).
      release checkpoint   Run the release checkpoint validation (no hardware).
      release checkpoint-hardware  Run checkpoint with ESP32-C6 smoke test.
         --device PATH      Override AXOLOTY_DEVICE (default: /dev/ttyACM0).
      measure timing        Measure cold/warm hardware-free builds (Linux only).
      repository validate    Validate version, documentation, and architecture authority.
      serve mqtt           Start a local Mosquitto broker in the foreground.
      serve mcp            Start an Axoloty MCP server (stdio or HTTP).
      serve dev            Start MQTT + MCP as a supervised development stack.

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """

    private static func usage(executableName: String) -> String {
        usage.replacingOccurrences(of: "axoloty-tool", with: executableName)
    }

    private static func timingUsage(executableName: String) -> String {
        """
        Usage: \(executableName) measure timing [options]

        Measure cold and warm hardware-free build paths on Linux.

        Options:
          --filter FILTER       Focused Swift test filter (default: AxolotyCommandDispatcherTests).
          --scratch-root PATH   Root for isolated per-scenario scratch trees.
          --keep-scratch        Retain scratch trees after measurement.
          --help                Show this help.
        """
    }

    private static let mqttUsage = """
    Usage: axoloty-tool serve mqtt [options]

    Start a local Mosquitto broker in the foreground.

    Options:
      --listen-host HOST  Bind the broker to HOST (default: 127.0.0.1).
      --port PORT         Listen on PORT (default: 1883).
      --output MODE       Use human or json output (default: human).
      --log-level LEVEL   Use error, warning, info, or debug (default: info).
      --help              Show this help.
    """

    private static let mcpUsage = """
    Usage: axoloty-tool serve mcp --transport TRANSPORT [options]

    Start an Axoloty MCP server using stdio or loopback HTTP.

    Options:
      --transport MODE        Use stdio or http (required).
      --listen-host HOST      HTTP bind address (default: 127.0.0.1).
      --listen-port PORT      HTTP listen port (default: 8765).
      --path PATH             HTTP endpoint path (default: /mcp).
      --broker-host HOST      MQTT broker host (default: localhost).
      --broker-port PORT      MQTT broker port (default: 1883).
      --namespace NAMESPACE   Coaty namespace (default: -).
      --connect-timeout TIME  Broker readiness timeout (default: 10s).
      --output MODE           HTTP output: human or json (default: human).
      --help                  Show this help.

    The HTTP-specific options are not valid with --transport stdio.
    """

    private static let developmentUsage = """
    Usage: axoloty-tool serve dev [options]

    Start MQTT and MCP as a supervised local development stack.

    Options:
      --namespace NAMESPACE  Coaty namespace (default: -).
      --mqtt-port PORT       MQTT listen port (default: 1883).
      --mcp-port PORT        MCP HTTP listen port (default: 8765).
      --output MODE          Use human or json output (default: human).
      --help                 Show this help.
    """

    private static func serveUsage(topic: AxolotyServeHelpTopic, executableName: String) -> String {
        let usage = switch topic {
        case .mqtt: mqttUsage
        case .mcp: mcpUsage
        case .dev: developmentUsage
        }
        return usage.replacingOccurrences(of: "axoloty-tool", with: executableName)
    }

    private func timingResult(arguments: [String]) -> AxolotyCommandResult {
        if arguments == ["--help"] || arguments == ["-h"] {
            return AxolotyCommandResult(standardOutput: Self.timingUsage(executableName: executableName))
        }
        let parsed = AxolotyTimingArgumentParser.parse(arguments)
        guard let options = parsed.success else {
            let message = parsed.failure?.message ?? "invalid timing arguments"
            return AxolotyCommandResult(
                standardError: "error: \(message)\n\n\(Self.timingUsage(executableName: executableName))\n",
                exitCode: 64
            )
        }
        let report = timingRunner.run(options)
        do {
            return try Self.jsonResult(report, exitCode: report.exitCode)
        } catch {
            let diagnostic = AxolotyTimingOutputParser.boundedDiagnostic(String(reflecting: error))
                ?? "unknown encoding error"
            return AxolotyCommandResult(
                standardError: "error: unable to encode timing report: \(diagnostic)\n",
                exitCode: 70
            )
        }
    }

    private func repositoryAuthorityResult(arguments: [String]) -> AxolotyCommandResult {
        var format = "human"
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                format = "json"
            case "--format":
                guard index + 1 < arguments.count, ["human", "json"].contains(arguments[index + 1]) else {
                    return AxolotyCommandResult(
                        standardError: "error: repository validate --format requires human or json\n",
                        exitCode: 64
                    )
                }
                format = arguments[index + 1]
                index += 1
            case "--help", "-h":
                return AxolotyCommandResult(standardOutput: "Usage: axoloty-tool repository validate [--format human|json]\n")
            default:
                return AxolotyCommandResult(
                    standardError: "error: unsupported repository validate option: \(arguments[index])\n",
                    exitCode: 64
                )
            }
            index += 1
        }
        let report = AxolotyRepositoryAuthorityValidator(root: repositoryRoot).validate()
        if format == "json" {
            return (try? Self.jsonResult(report, exitCode: report.status == "passed" ? 0 : 1))
                ?? AxolotyCommandResult(standardError: "error: unable to encode repository authority report\n", exitCode: 70)
        }
        if report.findings.isEmpty {
            return AxolotyCommandResult(standardOutput: "repository authority: passed\n")
        }
        let lines = report.findings.map { finding in
            let location = finding.path.map { " [\($0)]" } ?? ""
            return "- \(finding.rule)\(location): \(finding.message)"
        }
        return AxolotyCommandResult(
            standardOutput: "repository authority: failed\n\(lines.joined(separator: "\n"))\n",
            exitCode: 1
        )
    }

    private func serveResult(arguments: [String]) -> AxolotyCommandResult {
        let parser = AxolotyServeParser()
        switch parser.parse(arguments: arguments, environment: environment) {
        case .success(let command):
            switch command {
            case .help(let topic):
                return AxolotyCommandResult(
                    standardOutput: Self.serveUsage(topic: topic, executableName: executableName)
                )
            case .mqtt(let config):
                let runner = AxolotyMQTTServiceRunner(
                    processRunner: processRunnerFactory(),
                    portProbe: portProbe,
                    fileSystem: fileSystem,
                    tempDirProvider: tempDirProvider,
                    mosquittoExecutable: environment["AXOLOTY_MOSQUITTO_EXECUTABLE"] ?? "/usr/sbin/mosquitto",
                    installSignalHandler: false,
                    cancellation: cancellation
                )
                let exitCode = runner.run(config)
                return AxolotyCommandResult(exitCode: exitCode)
            case .mcp(let config):
                let runner = AxolotyMCPServiceRunner(
                    processRunner: processRunnerFactory(),
                    portProbe: portProbe,
                    fileSystem: fileSystem,
                    mcpExecutable: environment["AXOLOTY_MCP_EXECUTABLE"] ?? "/opt/axoloty/bin/axoloty-mcp",
                    installSignalHandler: false,
                    cancellation: cancellation
                )
                let exitCode = runner.run(config)
                return AxolotyCommandResult(exitCode: exitCode)
            case .development(let config):
                let runner = AxolotyDevelopmentServiceRunner(
                    processRunnerFactory: processRunnerFactory,
                    portProbe: portProbe,
                    fileSystem: fileSystem,
                    tempDirProvider: tempDirProvider,
                    mosquittoExecutable: environment["AXOLOTY_MOSQUITTO_EXECUTABLE"] ?? "/usr/sbin/mosquitto",
                    mcpExecutable: environment["AXOLOTY_MCP_EXECUTABLE"] ?? "/opt/axoloty/bin/axoloty-mcp",
                    installSignalHandler: false,
                    cancellation: cancellation
                )
                let exitCode = runner.run(config)
                return AxolotyCommandResult(exitCode: exitCode)
            }
        case .failure(let error):
            return AxolotyCommandResult(
                standardError: "error: \(error.userFriendlyMessage)\n",
                exitCode: 64
            )
        }
    }

    private func planResult(environment: [String: String]) -> AxolotyCommandResult {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let plan = try manifest.plan(named: "offline")
            return try Self.jsonResult(plan)
        } catch let error as AxolotyCanonicalTestManifestError {
            return AxolotyCommandResult(
                standardError: "error: \(error.userFriendlyMessage)\n",
                exitCode: 70
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func checkResult(requested: [String]? = nil) -> AxolotyCommandResult {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let availablePlan = try manifest.plan(named: "offline")
            guard requested?.allSatisfy({ requestedName in
                availablePlan.nodes.contains { $0.name == requestedName }
            }) != false else {
                return AxolotyCommandResult(
                    standardError: "error: requested check is unavailable on this platform\n",
                    exitCode: 69
                )
            }
            let plan = try AxolotyCheckPlanner().plan(
                availablePlan.nodes,
                requested: requested,
                deadlineSeconds: availablePlan.deadlineSeconds
            )
            let execution = executor.executeWithSummary(plan)
            let exitCode: Int32 = execution.results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(
                AxolotyCheckManifest(results: execution.results, execution: execution.summary),
                exitCode: exitCode
            )
        } catch let error as AxolotyCanonicalTestManifestError {
            return AxolotyCommandResult(
                standardError: "error: \(error.userFriendlyMessage)\n",
                exitCode: 70
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func verifyResult(ci: Bool) -> AxolotyCommandResult {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let plan = try manifest.plan(named: "verify", ci: ci)
            return execute(plan: plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func testOneResult(filter: String) -> AxolotyCommandResult {
        guard !filter.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: test-one requires a non-empty FILTER or --filter value\n",
                exitCode: 64
            )
        }
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let command: AxolotyCommandPlan
            if let node = try? manifest.node(named: filter),
               node.filter == nil,
               node.local,
               node.isAvailable(on: AxolotyCheckPlan.currentPlatform) {
                command = node.checkNode().command
            } else {
                command = manifest.testOneCommand(filter: filter)
            }
            if let failure = contextValidator.failureResult(validating: [command]) {
                return Self.commandResult(failure)
            }
            let result = run(command, context: AxolotyCommandRunContext(node: "test-one", stage: "check"))
            let check = AxolotyCheckResult(
                name: "test-one",
                status: result.exitCode == 0 ? .passed : .failed,
                command: result
            )
            return manifestResult(AxolotyCheckManifest(results: [check]), exitCode: result.exitCode == 0 ? 0 : 1)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func testTierResult(tier: String, ci: Bool) -> AxolotyCommandResult {
        guard !tier.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: test-tier requires a non-empty TIER or tier argument\n",
                exitCode: 64
            )
        }
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let plan = try manifest.plan(tier: tier, ci: ci)
            return execute(plan: plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
    }

    private func explainResult(tier: String, ci: Bool) -> AxolotyCommandResult {
        guard !tier.isEmpty else {
            return AxolotyCommandResult(
                standardError: "error: explain requires a non-empty TIER or tier argument\n",
                exitCode: 64
            )
        }
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let explanation = try manifest.explanation(tier: tier, ci: ci)
            if outputMode == .json {
                return try Self.jsonResult(explanation)
            }
            return AxolotyCommandResult(standardOutput: humanExplanation(explanation))
        } catch let error as AxolotyCanonicalTestManifestError {
            return AxolotyCommandResult(
                standardError: "error: \(error.userFriendlyMessage)\n",
                exitCode: 69
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
    }

    private func fixtureBundleResult() -> AxolotyCommandResult {
        do {
            let source = environment["AXOLOTY_FIXTURE_BUNDLE_SOURCE"] ?? "Tests/AxolotyTests/WireCompatibility/Fixtures"
            let destination = environment["AXOLOTY_FIXTURE_BUNDLE_OUTPUT"] ?? ".testing/fixture-bundle"
            let forwardedEnvironment = [
                "AXOLOTY_IMAGE_IDENTITY", "AXOLOTY_GIT_COMMIT", "AXOLOTY_GIT_CLEAN",
                "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
                "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
            ]
                .reduce(into: [String: String]()) { values, name in
                    values[name] = environment[name]
                }
            let sourcePlan = AxolotyCheckPlan.releaseSnapshots(
                source: source,
                destination: destination,
                environment: forwardedEnvironment
            )
            let plan = try AxolotyCheckPlanner().plan(
                sourcePlan.nodes,
                deadlineSeconds: sourcePlan.deadlineSeconds
            )
            let execution = executor.executeWithSummary(plan)
            let exitCode: Int32 = execution.results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(
                AxolotyCheckManifest(results: execution.results, execution: execution.summary),
                exitCode: exitCode
            )
        } catch {
            return AxolotyCommandResult(
                standardError: "error: unable to generate fixture bundle\n",
                exitCode: 70
            )
        }
    }

    private func wireBundleResult(path: String) -> AxolotyCommandResult {
        do {
            let manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
            let canonicalPlan = try manifest.plan(named: "wire-bundle")
            let plan = AxolotyCheckPlan(
                schemaVersion: canonicalPlan.schemaVersion,
                nodes: canonicalPlan.nodes.map { node in
                    AxolotyCheckNode(
                        name: node.name,
                        dependencies: node.dependencies,
                        command: AxolotyCommandPlan(
                            executable: node.command.executable,
                            arguments: node.command.arguments.map { argument in
                                argument == "${BUNDLE}" ? path : argument
                            },
                            environment: node.command.environment,
                            executionContext: node.command.executionContext,
                            timeoutSeconds: node.command.timeoutSeconds
                        ),
                        resources: node.resources,
                        isolation: node.isolation,
                        lane: node.lane
                    )
                },
                deadlineSeconds: canonicalPlan.deadlineSeconds
            )
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func integrationResult() -> AxolotyCommandResult {
        AxolotyCommandResult(
            standardError: "error: broker-backed integration tier is retired; use a declared test tier or wire capture for broker evidence\n",
            exitCode: 69
        )
    }

    private func checkpointResult(hardware: Bool) -> AxolotyCommandResult {
        let plan: AxolotyCheckPlan
        let device: String?
        let consumerEnvironment = [
            "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
            "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
        ].reduce(into: [String: String]()) { values, name in
            values[name] = environment[name]
        }
        let snapshotSource = environment["AXOLOTY_FIXTURE_BUNDLE_SOURCE"]
            ?? "Tests/AxolotyTests/WireCompatibility/Fixtures"
        let snapshotDestination = environment["AXOLOTY_FIXTURE_BUNDLE_OUTPUT"]
            ?? ".testing/fixture-bundle"
        let canonicalManifest: AxolotyCanonicalTestManifest
        do {
            canonicalManifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
        if hardware {
            let selectedDevice = environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
            device = selectedDevice
            plan = AxolotyCheckPlan.checkpointHardware(
                device: selectedDevice,
                source: snapshotSource,
                destination: snapshotDestination,
                consumerEnvironment: consumerEnvironment
            )
        } else {
            device = nil
            plan = AxolotyCheckPlan.checkpoint(
                source: snapshotSource,
                destination: snapshotDestination,
                consumerEnvironment: consumerEnvironment
            )
        }

        let gitCommitCommand = AxolotyCommandPlan(
            executable: "git", arguments: ["rev-parse", "--short", "HEAD"], timeoutSeconds: 60
        )
        let gitStatusCommand = AxolotyCommandPlan(
            executable: "git", arguments: ["status", "--porcelain"], timeoutSeconds: 60
        )
        let gitBranchCommand = AxolotyCommandPlan(
            executable: "git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"], timeoutSeconds: 60
        )
        let swiftVersionCommand = AxolotyCommandPlan(
            executable: "swift", arguments: ["--version"], timeoutSeconds: 60
        )
        let metadataCommands = (environment["AXOLOTY_GIT_COMMIT"] == nil ? [gitCommitCommand] : [])
            + [gitStatusCommand, gitBranchCommand, swiftVersionCommand]
        if let failure = contextValidator.failureResult(
            validating: plan.nodes.map(\.command) + metadataCommands
        ) {
            return Self.commandResult(failure)
        }
        if let device, !fileSystem.exists(atPath: device) {
            return AxolotyCommandResult(
                standardError: "error: checkpoint-hardware requires a device at \(device)\n",
                exitCode: 1
            )
        }

        do {
            let planned = try AxolotyCheckPlanner().plan(
                plan.nodes,
                deadlineSeconds: plan.deadlineSeconds
            )
            let results = executor.execute(planned)
            let gitCommit = environment["AXOLOTY_GIT_COMMIT"]
                ?? commandRunner.run(gitCommitCommand).standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            let gitStatus = commandRunner.run(gitStatusCommand).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let gitBranch = commandRunner.run(gitBranchCommand).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let swiftVersion = commandRunner.run(swiftVersionCommand).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let releaseGates = Self.releaseGateDispositions(
                manifest: canonicalManifest,
                results: results,
                environment: environment
            )
            let manifest = AxolotyCheckpointManifest(
                releaseVersion: Self.version,
                gitCommit: gitCommit,
                gitClean: gitStatus.isEmpty,
                gitBranch: gitBranch,
                swiftVersion: swiftVersion,
                hardwareIncluded: hardware,
                results: results,
                releaseGates: releaseGates,
                timestamp: timestamp
            )
            let releaseGateMissingEvidence = releaseGates.contains { $0.result == .skipped }
            // A release gate that the checkpoint could not execute or attest is a missing
            // mandatory release tier, so the checkpoint must not certify the release.
            let exitCode: Int32 = (results.allSatisfy { $0.status == .passed }
                && !releaseGateMissingEvidence) ? 0 : 1
            return checkpointManifestResult(manifest, exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: unable to plan checkpoint\n",
                exitCode: 70
            )
        }
    }

    private func execute(plan availablePlan: AxolotyCheckPlan) -> AxolotyCommandResult {
        do {
            let plan = try AxolotyCheckPlanner().plan(
                availablePlan.nodes,
                deadlineSeconds: availablePlan.deadlineSeconds
            )
            let execution = executor.executeWithSummary(plan)
            let exitCode: Int32 = execution.results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(
                AxolotyCheckManifest(results: execution.results, execution: execution.summary),
                exitCode: exitCode
            )
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to plan checks\n", exitCode: 70)
        }
    }

    private func humanExplanation(_ explanation: AxolotyCanonicalTestExplanation) -> String {
        let deadline = explanation.timeoutSeconds.map { String($0) } ?? "none"
        var lines = [
            "PLAN \(explanation.name) schema=\(explanation.schemaVersion) ci=\(explanation.ci) deadline=\(deadline)",
        ]
        lines += explanation.nodes.map { node in
            let dependencies = node.dependencies.isEmpty ? "-" : node.dependencies.joined(separator: ",")
            let lane = node.lane ?? "-"
            let resources = node.resources.isEmpty ? "-" : node.resources.joined(separator: ",")
            let artifacts = node.artifacts.isEmpty ? "-" : node.artifacts.joined(separator: ",")
            let arguments = ([node.executable] + node.arguments).map { argument in
                argument.contains(" ") ? "\"\(argument)\"" : argument
            }.joined(separator: " ")
            return "\(node.id): \(arguments)\n  depends=\(dependencies) duration=\(node.expectedDurationSeconds)s deadline=\(node.timeoutSeconds)s\n  policy network=\(node.network.rawValue) broker=\(node.broker.rawValue) hardware=\(node.hardware.rawValue) isolation=\(node.isolation.rawValue) lane=\(lane) resources=\(resources) artifacts=\(artifacts)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func hardwareResult(required: Bool, device: String?) -> AxolotyCommandResult {
        let selectedDevice = device ?? environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
        let command = AxolotyCommandPlan(
            executable: "Tests/Support/embedded-swift-test.sh",
            environment: ["EMBEDDED_DEVICE": selectedDevice],
            timeoutSeconds: 10 * 60
        )
        if let failure = contextValidator.failureResult(validating: [command]) {
            return Self.commandResult(failure)
        }
        guard fileSystem.exists(atPath: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device is not present"
            )
            return (try? Self.jsonResult(outcome, exitCode: required ? 1 : 0)) ?? AxolotyCommandResult(exitCode: 70)
        }
        guard let lease = deviceLeaseManager.acquire(device: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device lease is unavailable"
            )
            return (try? Self.jsonResult(outcome, exitCode: required ? 1 : 0)) ?? AxolotyCommandResult(exitCode: 70)
        }
        let result = commandRunner.run(command)
        withExtendedLifetime(lease) {}
        let outcome = AxolotyHardwareOutcome(
            status: result.exitCode == 0 ? .passed : .failed,
            device: selectedDevice,
            reason: result.exitCode == 0
                ? "hardware smoke test passed"
                : (result.standardError.isEmpty
                    ? "hardware smoke test failed"
                    : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return (try? Self.jsonResult(outcome, exitCode: result.exitCode == 0 ? 0 : 1)) ?? AxolotyCommandResult(exitCode: 70)
    }

    private static func jsonResult<Value: Encodable>(
        _ value: Value,
        exitCode: Int32 = 0
    ) throws -> AxolotyCommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return AxolotyCommandResult(
            standardOutput: String(decoding: data, as: UTF8.self),
            exitCode: exitCode
        )
    }

    private func manifestResult(
        _ manifest: AxolotyCheckManifest,
        exitCode: Int32
    ) -> AxolotyCommandResult {
        guard outputMode == .human else {
            return (try? Self.jsonResult(manifest, exitCode: exitCode))
                ?? AxolotyCommandResult(exitCode: 70)
        }
        return AxolotyCommandResult(
            standardOutput: humanSummary(manifest.results),
            exitCode: exitCode
        )
    }

    private func checkpointManifestResult(
        _ manifest: AxolotyCheckpointManifest,
        exitCode: Int32
    ) -> AxolotyCommandResult {
        guard outputMode == .human else {
            return (try? Self.jsonResult(manifest, exitCode: exitCode))
                ?? AxolotyCommandResult(exitCode: 70)
        }
        return AxolotyCommandResult(
            standardOutput: humanSummary(manifest.results),
            exitCode: exitCode
        )
    }

    private func humanSummary(_ results: [AxolotyCheckResult]) -> String {
        results.map { "\($0.status.rawValue.uppercased()) \($0.name)" }.joined(separator: "\n") + "\n"
    }

    /// Classifies each mandatory release gate based on covering node results.
    ///
    /// A gate is ``AxolotyCheckpointGateResult/executed`` when every covering node
    /// passed, ``failed`` when any covering node failed, ``attested`` when an
    /// `AXOLOTY_ATTESTATION_<GATE>_PATH` environment value supplies external evidence,
    /// and ``skipped`` when no covering node ran and no attestation exists. The
    /// checkpoint fails on any skipped gate so a release cannot be certified with
    /// missing mandatory-tier evidence.
    private static func releaseGateDispositions(
        manifest: AxolotyCanonicalTestManifest,
        results: [AxolotyCheckResult],
        environment: [String: String]
    ) -> [AxolotyCheckpointGate] {
        let resultByName = Dictionary(
            uniqueKeysWithValues: results.map { ($0.name, $0) }
        )
        return manifest.releaseGates.map { gate in
            let coveringNodes = manifest.tiers.first { $0.id == gate }?.nodes ?? []
            let coveringResults = coveringNodes.compactMap { resultByName[$0] }
            let normalizedGate = gate.uppercased().replacingOccurrences(of: "-", with: "_")
            let attestationKey = "AXOLOTY_ATTESTATION_\(normalizedGate)_PATH"
            if let evidence = environment[attestationKey], !evidence.isEmpty {
                return AxolotyCheckpointGate(
                    id: gate,
                    result: .attested,
                    nodes: coveringResults,
                    evidence: evidence,
                    note: "externally attested release gate"
                )
            }
            if coveringResults.isEmpty {
                return AxolotyCheckpointGate(
                    id: gate,
                    result: .skipped,
                    nodes: [],
                    note: "no covering node ran in the checkpoint and no attestation was supplied"
                )
            }
            if coveringResults.allSatisfy({ $0.status == .passed }) {
                return AxolotyCheckpointGate(id: gate, result: .executed, nodes: coveringResults)
            }
            if coveringResults.contains(where: { $0.status == .failed }) {
                return AxolotyCheckpointGate(id: gate, result: .failed, nodes: coveringResults)
            }
            return AxolotyCheckpointGate(
                id: gate,
                result: .skipped,
                nodes: coveringResults,
                note: "covering node was skipped"
            )
        }
    }

    private var executor: AxolotyCheckExecutor {
        AxolotyCheckExecutor(
            commandRunner: CanonicalTierCommandRunner(
                commandRunner: commandRunner,
                integrationRunner: integrationRunner
            ),
            contextValidator: contextValidator,
            cancellation: cancellation,
            maxConcurrentNodes: maxConcurrentChecks
        )
    }

    private var maxConcurrentChecks: Int {
        if let value = environment["AXOLOTY_MAX_CONCURRENT_CHECKS"].flatMap(Int.init), value > 0 {
            return value
        }
        return environment["CI"] == "true" ? 2 : 1
    }

    private static func commandResult(_ result: AxolotyCheckCommandResult) -> AxolotyCommandResult {
        AxolotyCommandResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitCode: result.exitCode
        )
    }

    private func run(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) -> AxolotyCheckCommandResult {
        if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
            return lifecycleRunner.run(command, context: context)
        }
        return commandRunner.run(command)
    }
}
// swiftlint:enable type_body_length

private struct CanonicalTierCommandRunner: AxolotyLifecycleCommandRunning {
    let commandRunner: any AxolotyCheckCommandRunning
    let integrationRunner: any AxolotyIntegrationRunning

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commandRunner.run(command)
    }

    func run(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) -> AxolotyCheckCommandResult {
        if context.node == "integration-tests" {
            if let boundedRunner = integrationRunner as? any AxolotyBoundedIntegrationRunning {
                return boundedRunner.run(timeoutSeconds: command.timeoutSeconds)
            }
            return integrationRunner.run()
        }
        if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
            return lifecycleRunner.run(command, context: context)
        }
        return commandRunner.run(command)
    }
}

/// The standard streams and status produced by an ``AxolotyCommandDispatcher``.
public struct AxolotyCommandResult: Equatable, Sendable {
    /// Text to write to standard output.
    public let standardOutput: String

    /// Text to write to standard error.
    public let standardError: String

    /// Process status to return to the caller.
    public let exitCode: Int32

    /// Creates a command result.
    ///
    /// - Parameters:
    ///   - standardOutput: Text to write to standard output.
    ///   - standardError: Text to write to standard error.
    ///   - exitCode: Process status to return to the caller.
    public init(
        standardOutput: String = "",
        standardError: String = "",
        exitCode: Int32 = 0
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

}
