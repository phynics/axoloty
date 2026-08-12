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
            execute(plan: AxolotyCheckPlan.wireCapture)
        case ["embedded", "build"]:
            checkResult(requested: ["embedded-build"])
        case ["embedded", "doctor"]:
            checkResult(requested: ["embedded-toolchain"])
        case ["embedded", "verify"]:
            checkResult(requested: ["embedded-linker"])
        case ["release", "snapshots"]:
            releaseSnapshotsResult()
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

    private static let version = "0.2.0"

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
      test integration     Run transport tests against local Mosquitto.
      wire verify [BUNDLE] Verify fixtures and an optional bundle without MQTT.
      wire capture         Run live MQTT captures with pinned reference agents.
      embedded build       Cross-compile the ESP32-C6 firmware on Linux.
      embedded doctor      Verify the container's ESP-IDF build environment.
      embedded verify      Build and verify the ESP32-C6 linker contract.
      hardware check       Run or skip the sporadic hardware smoke check.
      hardware require     Require an attached device and run its smoke check.
      release snapshots    Generate and verify a provenance-rich wire bundle.
      release checkpoint   Run the 0.2 checkpoint validation (no hardware).
      release checkpoint-hardware  Run checkpoint with ESP32-C6 smoke test.
         --device PATH      Override AXOLOTY_DEVICE (default: /dev/ttyACM0).
      serve mqtt           Start a local Mosquitto broker in the foreground.
      serve mcp            Start an Axoloty MCP server (stdio or HTTP).
      serve dev            Start MQTT + MCP as a supervised development stack.

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """

    private static func usage(executableName: String) -> String {
        usage.replacingOccurrences(of: "axoloty-tool", with: executableName)
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
            let plan = try AxolotyCheckPlanner().plan(availablePlan.nodes, requested: requested)
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
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
            let command = manifest.testOneCommand(filter: filter)
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

    private func releaseSnapshotsResult() -> AxolotyCommandResult {
        do {
            let source = environment["AXOLOTY_SNAPSHOT_SOURCE"] ?? "Tests/WireCompatibility/Fixtures"
            let destination = environment["AXOLOTY_SNAPSHOT_OUTPUT"] ?? ".testing/release-snapshots"
            let forwardedEnvironment = [
                "AXOLOTY_IMAGE_IDENTITY", "AXOLOTY_GIT_COMMIT", "AXOLOTY_GIT_CLEAN",
                "AXOLOTY_CONSUMER_REPOSITORY_URL", "AXOLOTY_CONSUMER_VERSION",
                "AXOLOTY_CONSUMER_LOCAL", "AXOLOTY_CONSUMER_LOCAL_VERSION",
            ]
                .reduce(into: [String: String]()) { values, name in
                    values[name] = environment[name]
                }
            let plan = try AxolotyCheckPlanner().plan(
                AxolotyCheckPlan.releaseSnapshots(
                    source: source,
                    destination: destination,
                    environment: forwardedEnvironment
                ).nodes
            )
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: unable to generate release snapshots\n",
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
                        )
                    )
                }
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
        if let failure = contextValidator.failureResult(
            validating: FoundationIntegrationRunner.commandPlans
        ) {
            return Self.commandResult(failure)
        }
        let command = integrationRunner.run()
        let result = AxolotyCheckResult(
            name: "integration-tests",
            status: command.exitCode == 0 ? .passed : .failed,
            command: command
        )
        return manifestResult(
            AxolotyCheckManifest(results: [result]),
            exitCode: command.exitCode == 0 ? 0 : 1
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
        if hardware {
            let selectedDevice = environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
            device = selectedDevice
            plan = AxolotyCheckPlan.checkpointHardware(
                device: selectedDevice,
                consumerEnvironment: consumerEnvironment
            )
        } else {
            device = nil
            plan = AxolotyCheckPlan.checkpoint(consumerEnvironment: consumerEnvironment)
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
            let planned = try AxolotyCheckPlanner().plan(plan.nodes)
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
            let manifest = AxolotyCheckpointManifest(
                releaseVersion: "0.2.0",
                gitCommit: gitCommit,
                gitClean: gitStatus.isEmpty,
                gitBranch: gitBranch,
                swiftVersion: swiftVersion,
                hardwareIncluded: hardware,
                results: results,
                timestamp: timestamp
            )
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
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
            let plan = try AxolotyCheckPlanner().plan(availablePlan.nodes)
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to plan checks\n", exitCode: 70)
        }
    }

    private func humanExplanation(_ explanation: AxolotyCanonicalTestExplanation) -> String {
        var lines = [
            "PLAN \(explanation.name) schema=\(explanation.schemaVersion) ci=\(explanation.ci)",
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
            executable: "Tests/Support/embedded-swift-smoke.sh",
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

    private var executor: AxolotyCheckExecutor {
        AxolotyCheckExecutor(
            commandRunner: CanonicalTierCommandRunner(
                commandRunner: commandRunner,
                integrationRunner: integrationRunner
            ),
            contextValidator: contextValidator,
            cancellation: cancellation
        )
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
