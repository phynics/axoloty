// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyVersion

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
    private let version: String
    private let planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>

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
        let planResolution: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
        do {
            planResolution = .success(try AxolotyCanonicalTestPlanResolver(environment: environment))
        } catch let error as AxolotyCanonicalTestManifestError {
            planResolution = .failure(error)
        } catch {
            planResolution = .failure(.decodingFailure(
                path: environment["AXOLOTY_TEST_MANIFEST"] ?? "canonical test manifest",
                reason: error.localizedDescription
            ))
        }
        self.executableName = executableName
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.integrationRunner = integrationRunner ?? FoundationIntegrationRunner(
            commandRunner: commandRunner,
            contextValidator: contextValidator,
            planResolver: try? planResolution.get()
        )
        self.deviceLeaseManager = deviceLeaseManager
        self.fileSystem = fileSystem ?? FoundationFileSystem()
        self.environment = environment
        planResolver = planResolution
        self.processRunnerFactory = processRunnerFactory ?? { FoundationProcessRunner() }
        self.portProbe = portProbe ?? FoundationServiceProbe()
        self.tempDirProvider = tempDirProvider ?? FoundationTempDirectoryProvider()
        self.timingRunner = timingRunner ?? AxolotyTimingRunner(
            commandRunner: commandRunner,
            environment: environment,
            planResolver: planResolution
        )
        self.repositoryRoot = (repositoryRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        self.version = AxolotyVersion.current(environment: environment)
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
            AxolotyCommandResult(standardOutput: AxolotyCommandHelp.usage(executableName: executableName))
        case ["version"], ["--version"]:
            AxolotyCommandResult(standardOutput: "\(executableName) \(version)")
        case ["check", "--plan"]:
            planResult()
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
            wireCaptureResult()
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
                standardError: "error: unsupported \(executableName) command\n\n\(AxolotyCommandHelp.usage(executableName: executableName))\n",
                exitCode: 64
            )
        }
    }

    private static func manifestDiagnostic(_ error: Error) -> String {
        if let manifestError = error as? AxolotyCanonicalTestManifestError {
            return manifestError.userFriendlyMessage
        }
        return error.localizedDescription
    }

    private func timingResult(arguments: [String]) -> AxolotyCommandResult {
        if arguments == ["--help"] || arguments == ["-h"] {
            return AxolotyCommandResult(standardOutput: AxolotyCommandHelp.timingUsage(executableName: executableName))
        }
        let parsed = AxolotyTimingArgumentParser.parse(arguments)
        guard let options = parsed.success else {
            let message = parsed.failure?.message ?? "invalid timing arguments"
            return AxolotyCommandResult(
                standardError: "error: \(message)\n\n\(AxolotyCommandHelp.timingUsage(executableName: executableName))\n",
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
                return AxolotyCommandResult(standardOutput: AxolotyCommandHelp.repositoryValidationUsage)
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
                    standardOutput: AxolotyCommandHelp.serveUsage(topic: topic, executableName: executableName)
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

    private func planResult() -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.named(
                .offline,
                ci: false,
                platform: AxolotyCheckPlan.currentPlatform,
                requested: nil
            ))
            return try Self.jsonResult(plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
    }

    private func checkResult(requested: [String]? = nil) -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.named(
                .offline,
                ci: false,
                platform: AxolotyCheckPlan.currentPlatform,
                requested: requested
            ))
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch AxolotyCanonicalTestManifestError.unavailableNode(_) {
            return AxolotyCommandResult(
                standardError: "error: requested check is unavailable on this platform\n",
                exitCode: 69
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
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.named(
                .verify,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform,
                requested: nil
            ))
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
            let resolver = try planResolver.get()
            let command = try resolver.command(.testOneOrNode(
                value: filter,
                platform: AxolotyCheckPlan.currentPlatform
            ))
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
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.tier(
                name: tier,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform
            ))
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
            let resolver = try planResolver.get()
            let explanation = try resolver.explanation(for: .tier(
                name: tier,
                ci: ci,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            if outputMode == .json {
                return try Self.jsonResult(explanation)
            }
            return AxolotyCommandResult(standardOutput: humanExplanation(explanation))
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
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.fixtureBundle(
                source: source,
                destination: destination,
                environment: forwardedEnvironment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            let results = executor.execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: unable to generate fixture bundle\n",
                exitCode: 70
            )
        }
    }

    private func wireBundleResult(path: String) -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.downloadedWireBundle(
                path: path,
                platform: AxolotyCheckPlan.currentPlatform
            ))
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

    private func wireCaptureResult() -> AxolotyCommandResult {
        do {
            let resolver = try planResolver.get()
            let plan = try resolver.resolve(.wireCapture(
                environment: environment,
                platform: AxolotyCheckPlan.currentPlatform
            ))
            return execute(plan: plan)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 70
            )
        }
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
        let resolver: AxolotyCanonicalTestPlanResolver
        do {
            resolver = try planResolver.get()
        } catch {
            return AxolotyCommandResult(
                standardError: "error: \(Self.manifestDiagnostic(error))\n",
                exitCode: 69
            )
        }
        if hardware {
            let selectedDevice = environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
            device = selectedDevice
            do {
                plan = try resolver.resolve(.checkpoint(
                    hardwareDevice: selectedDevice,
                    source: snapshotSource,
                    destination: snapshotDestination,
                    consumerEnvironment: consumerEnvironment,
                    platform: AxolotyCheckPlan.currentPlatform
                ))
            } catch {
                return AxolotyCommandResult(
                    standardError: "error: \(Self.manifestDiagnostic(error))\n",
                    exitCode: 69
                )
            }
        } else {
            device = nil
            do {
                plan = try resolver.resolve(.checkpoint(
                    hardwareDevice: nil,
                    source: snapshotSource,
                    destination: snapshotDestination,
                    consumerEnvironment: consumerEnvironment,
                    platform: AxolotyCheckPlan.currentPlatform
                ))
            } catch {
                return AxolotyCommandResult(
                    standardError: "error: \(Self.manifestDiagnostic(error))\n",
                    exitCode: 69
                )
            }
        }

        let gitCommitCommand = AxolotyCommandPlan(
            executable: "git", arguments: ["rev-parse", "HEAD"], timeoutSeconds: 60
        )
        let gitTreeCommand = AxolotyCommandPlan(
            executable: "git", arguments: ["rev-parse", "HEAD^{tree}"], timeoutSeconds: 60
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
            + (environment["AXOLOTY_GIT_TREE"] == nil ? [gitTreeCommand] : [])
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

        let results = executor.execute(plan)
        let gitCommit = environment["AXOLOTY_GIT_COMMIT"]
            ?? commandRunner.run(gitCommitCommand).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitTree = environment["AXOLOTY_GIT_TREE"]
            ?? commandRunner.run(gitTreeCommand).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitStatus = commandRunner.run(gitStatusCommand).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitBranch = commandRunner.run(gitBranchCommand).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let swiftVersion = commandRunner.run(swiftVersionCommand).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let releaseVersion = Self.releaseVersion(at: repositoryRoot, fileSystem: fileSystem)
        let gitClean = gitStatus.isEmpty
        // Hardware inclusion is evidence-derived. A caller selecting the
        // hardware command is not proof that a device node actually ran;
        // every required hardware node present in this resolved plan must
        // have a passing result before the certificate advertises hardware.
        let hardwareResults = results.filter { result in
            resolver.manifest.nodes.first(where: { $0.id == result.name })?.hardware == .required
        }
        let validatedHardwareIncluded = !hardwareResults.isEmpty
            && hardwareResults.allSatisfy { $0.status == .passed }
        let releaseGates = Self.releaseGateDispositions(
            manifest: resolver.manifest,
            results: results,
            environment: environment,
            fileSystem: fileSystem,
            repositoryRoot: repositoryRoot,
            releaseVersion: releaseVersion,
            gitCommit: gitCommit,
            gitTree: gitTree,
            gitClean: gitClean
        )
        let manifest = AxolotyCheckpointManifest(
            releaseVersion: releaseVersion,
            gitCommit: gitCommit,
            gitTree: gitTree.isEmpty ? nil : gitTree,
            repository: environment["AXOLOTY_REPOSITORY"] ?? "github.com/phynics/axoloty",
            gitClean: gitClean,
            gitBranch: gitBranch,
            swiftVersion: swiftVersion,
            hardwareIncluded: validatedHardwareIncluded,
            results: results,
            releaseGates: releaseGates,
            timestamp: timestamp
        )
        let releaseGateMissingEvidence = releaseGates.contains { $0.result == .skipped }
        let releaseGateFailed = releaseGates.contains { $0.result == .failed }
        // A release gate that failed, could not execute, or lacked valid attestation
        // is mandatory evidence, so the checkpoint must not certify the release.
        let exitCode: Int32 = (results.allSatisfy { $0.status == .passed }
            && !releaseGateMissingEvidence
            && !releaseGateFailed
            && gitClean) ? 0 : 1
        return checkpointManifestResult(manifest, exitCode: exitCode)
    }

    private static func releaseVersion(at root: URL, fileSystem: any AxolotyFileSystem) -> String {
        guard let value = fileSystem.contents(atPath: root.appendingPathComponent("VERSION").path),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "unavailable"
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func execute(plan availablePlan: AxolotyCheckPlan) -> AxolotyCommandResult {
        let results = executor.execute(availablePlan)
        let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
        return manifestResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
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
    /// exact-subject evidence bundle is supplied by `AXOLOTY_EVIDENCE_DIR`, and
    /// ``skipped`` when no covering node ran and no evidence exists. An invalid
    /// evidence bundle is failed. The
    /// checkpoint fails on any skipped gate so a release cannot be certified with
    /// missing mandatory-tier evidence.
    private static func releaseGateDispositions(
        manifest: AxolotyCanonicalTestManifest,
        results: [AxolotyCheckResult],
        environment: [String: String],
        fileSystem: any AxolotyFileSystem,
        repositoryRoot: URL,
        releaseVersion: String,
        gitCommit: String,
        gitTree: String,
        gitClean: Bool
    ) -> [AxolotyCheckpointGate] {
        let resultByName = Dictionary(
            uniqueKeysWithValues: results.map { ($0.name, $0) }
        )
        return manifest.releaseGates.map { gate in
            let coveringNodes = manifest.tiers.first { $0.id == gate }?.nodes ?? []
            let coveringResults = coveringNodes.compactMap { resultByName[$0] }
            let normalizedGate = gate.uppercased().replacingOccurrences(of: "-", with: "_")
            let legacyKey = "AXOLOTY_ATTESTATION_\(normalizedGate)_PATH"
            let evidenceRoot = environment["AXOLOTY_EVIDENCE_DIR"]
            let evidenceBundle: String? = if let root = environment["AXOLOTY_EVIDENCE_DIR"], !root.isEmpty {
                URL(fileURLWithPath: root, relativeTo: repositoryRoot)
                    .appendingPathComponent(gate)
                    .path
            } else if let path = environment[legacyKey], !path.isEmpty {
                path
            } else {
                nil
            }
            if let evidenceBundle,
               fileSystem.exists(atPath: evidenceBundle) {
                guard let repository = try? AxolotyRepositoryIdentity(
                    environment["AXOLOTY_REPOSITORY"] ?? "github.com/phynics/axoloty"
                ),
                let commit = try? AxolotyGitCommitSHA(gitCommit),
                let tree = try? AxolotyGitTreeSHA(gitTree),
                let version = try? AxolotySemanticVersion(releaseVersion) else {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidenceBundle,
                        note: "evidence requires full commit/tree and semantic version metadata"
                    )
                }
                let subject = AxolotyReleaseSubject(
                    repository: repository,
                    commit: commit,
                    tree: tree,
                    version: version,
                    clean: gitClean
                )
                let bundleURL = URL(fileURLWithPath: evidenceBundle, relativeTo: repositoryRoot)
                    .standardizedFileURL
                do {
                    let validated = try AxolotyEvidenceBundleLoader().validate(
                        bundle: bundleURL,
                        expectedGate: AxolotyReleaseGateID(rawValue: gate),
                        context: AxolotyEvidenceValidationContext(
                            expectedSubject: subject,
                            bundleRoot: bundleURL
                        )
                    )
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .attested,
                        nodes: coveringResults,
                        evidence: evidenceBundle,
                        evidenceDigest: validated.bundleDigest,
                        note: "exact-subject evidence bundle validated"
                    )
                } catch let error as AxolotyReleaseEvidenceError {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidenceBundle,
                        note: error.localizedDescription
                    )
                } catch {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: coveringResults,
                        evidence: evidenceBundle,
                        note: "evidence validation failed: \(error.localizedDescription)"
                    )
                }
            }
            let explicitlyRequestedLegacyEvidence = environment[legacyKey]?.isEmpty == false
            if let evidenceBundle,
               !evidenceBundle.isEmpty,
               explicitlyRequestedLegacyEvidence,
               evidenceRoot == nil {
                return AxolotyCheckpointGate(
                    id: gate,
                    result: .failed,
                    nodes: coveringResults,
                    evidence: evidenceBundle,
                    note: "evidence bundle path is missing"
                )
            }
            if coveringResults.isEmpty {
                if let evidenceRoot, !evidenceRoot.isEmpty {
                    return AxolotyCheckpointGate(
                        id: gate,
                        result: .failed,
                        nodes: [],
                        evidence: evidenceBundle,
                        note: "required evidence bundle is missing"
                    )
                }
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
