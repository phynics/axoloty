// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyVersion

// swiftlint:disable type_body_length file_length cyclomatic_complexity function_body_length
/// Parses the stable command surface of the ``axoloty-tool`` executable.
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
    private let executor: AxolotyCheckExecutor
    private let releaseCommands: AxolotyReleaseCommands

    /// Creates a dispatcher from live executable configuration.
    ///
    /// - Parameters:
    ///   - executableName: The executable name used in help and version output.
    ///   - environment: Environment variables used by command parsing and execution.
    ///   - repositoryRoot: Repository checkout used by authority validation.
    ///   - installSignalHandler: Whether this invocation owns process signals.
    public init(
        executableName: String = "axoloty-tool",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        repositoryRoot: URL? = nil,
        installSignalHandler: Bool = true
    ) {
        self.init(
            executableName: executableName,
            commandRunner: FoundationCommandRunner(),
            environment: environment,
            repositoryRoot: repositoryRoot,
            installSignalHandler: installSignalHandler
        )
    }

    /// Creates a dispatcher with injected process and service boundaries.
    ///
    /// This initializer is internal so command tests and first-party tooling
    /// can exercise boundaries without expanding the executable's public
    /// configuration surface.
    init(
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
        cancellation: AxolotyCommandCancellation? = nil,
        eventSink: (@Sendable (AxolotyCheckExecutionEvent) -> Void)? = nil,
        timestampProvider: (@Sendable () -> String)? = nil,
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock(),
        overrunScheduler: any AxolotyOverrunScheduling = DispatchOverrunScheduler()
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
        let integrationRunner = integrationRunner ?? FoundationIntegrationRunner(
            commandRunner: commandRunner,
            contextValidator: contextValidator,
            planResolver: try? planResolution.get()
        )
        let fileSystem = fileSystem ?? FoundationFileSystem()
        let normalizedRepositoryRoot = (repositoryRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        self.deviceLeaseManager = deviceLeaseManager
        self.fileSystem = fileSystem
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
        self.repositoryRoot = normalizedRepositoryRoot
        self.version = AxolotyVersion.current(environment: environment)
        self.installSignalHandler = installSignalHandler && runnerConfiguration.installSignalHandler
        self.cancellation = invocationCancellation
        outputMode = runnerConfiguration.outputMode
        let executor = AxolotyCheckExecutor(
            commandRunner: CanonicalTierCommandRunner(
                commandRunner: commandRunner,
                integrationRunner: integrationRunner
            ),
            contextValidator: contextValidator,
            cancellation: invocationCancellation,
            clock: clock,
            overrunScheduler: overrunScheduler,
            eventSink: eventSink ?? { event in
                try? FileHandle.standardError.write(contentsOf: Data(event.diagnosticLine().utf8))
            }
        )
        self.integrationRunner = integrationRunner
        self.executor = executor
        self.releaseCommands = AxolotyReleaseCommands(
            commandRunner: commandRunner,
            contextValidator: contextValidator,
            fileSystem: fileSystem,
            environment: environment,
            repositoryRoot: normalizedRepositoryRoot,
            outputMode: runnerConfiguration.outputMode,
            resolver: planResolution,
            executor: executor,
            timestampProvider: timestampProvider ?? {
                ISO8601DateFormatter().string(from: Date())
            }
        )
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
        let invocation = AxolotyCommandParser(environment: environment).parse(arguments)
        return route(invocation)
    }

    private func route(_ invocation: AxolotyCommandInvocation) -> AxolotyCommandResult {
        switch invocation {
        case .help:
            return AxolotyCommandResult(standardOutput: AxolotyCommandHelp.usage(executableName: executableName))
        case .version:
            return AxolotyCommandResult(standardOutput: "\(executableName) \(version)")
        case .unsupported:
            return AxolotyCommandResult(
                standardError: "error: unsupported \(executableName) command\n\n\(AxolotyCommandHelp.usage(executableName: executableName))\n",
                exitCode: 64
            )
        case .serve(let arguments): return serveResult(arguments: arguments)
        case .timing(let arguments): return timingResult(arguments: arguments)
        case .repositoryValidation(let arguments): return repositoryAuthorityResult(arguments: arguments)
        case .hardware(let required, let device): return hardwareResult(required: required, device: device)
        case .wireBundle(let path): return wireBundleResult(path: path)
        case .testOne(let filter): return testOneResult(filter: filter)
        case .testTier(let name, let ci): return testTierResult(tier: name, ci: ci)
        case .explain(let name, let ci): return explainResult(tier: name, ci: ci)
        case .checkPlan: return planResult()
        case .check(let requested): return checkResult(requested: requested)
        case .verify(let ci): return verifyResult(ci: ci)
        case .integration: return integrationResult()
        case .wireCapture: return wireCaptureResult()
        case .embeddedBuild: return checkResult(requested: ["embedded-build"])
        case .embeddedDoctor: return checkResult(requested: ["embedded-toolchain"])
        case .embeddedVerify: return checkResult(requested: ["embedded-linker"])
        case .release(let command): return releaseCommands.run(command)
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
            return execute(plan: plan, writeVerificationReport: ci)
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

    private func execute(
        plan availablePlan: AxolotyCheckPlan,
        writeVerificationReport: Bool = false
    ) -> AxolotyCommandResult {
        let results = executor.execute(availablePlan)
        let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
        if writeVerificationReport {
            guard let invocation = (commandRunner as? any AxolotyArtifactInvocationIdentifying)?.artifactInvocation else {
                return AxolotyCommandResult(
                    standardError: "error: verify-ci command runner does not expose an artifact invocation\n",
                    exitCode: 70
                )
            }
            do {
                _ = try AxolotyVerificationReportWriter().write(
                    plan: availablePlan,
                    results: results,
                    invocation: invocation
                )
            } catch {
                return AxolotyCommandResult(
                    standardError: "error: unable to publish verify-ci report: \(error.localizedDescription)\n",
                    exitCode: 70
                )
            }
        }
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
            standardOutput: String(bytes: data, encoding: .utf8) ?? "",
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

    private func humanSummary(_ results: [AxolotyCheckResult]) -> String {
        results.map { "\($0.status.rawValue.uppercased()) \($0.name)" }.joined(separator: "\n") + "\n"
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

// swiftlint:enable type_body_length file_length cyclomatic_complexity function_body_length
