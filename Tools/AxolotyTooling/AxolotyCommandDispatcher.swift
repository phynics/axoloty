// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyVersion

/// Parses the stable command surface of the ``axoloty-tool`` executable.
public struct AxolotyCommandDispatcher: Sendable {
    private let executableName: String
    private let environment: [String: String]
    private let installSignalHandler: Bool
    private let cancellation: AxolotyCommandCancellation
    private let version: String
    private let checkCommands: AxolotyCheckCommands
    private let wireCommands: AxolotyWireCommands
    private let hardwareCommands: AxolotyHardwareCommands
    private let serveCommands: AxolotyServeCommandRunner
    private let timingCommands: AxolotyTimingCommandRunner
    private let repositoryValidationCommands: AxolotyRepositoryValidationCommands
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
        let configuredCommandRunner: any AxolotyCheckCommandRunning = commandRunner is FoundationCommandRunner
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

        let integrationRunner = integrationRunner ?? FoundationIntegrationRunner(
            commandRunner: configuredCommandRunner,
            contextValidator: contextValidator,
            planResolver: try? planResolution.get()
        )
        let fileSystem = fileSystem ?? FoundationFileSystem()
        let normalizedRepositoryRoot = (repositoryRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        let processRunnerFactory = processRunnerFactory ?? { FoundationProcessRunner() }
        let portProbe = portProbe ?? FoundationServiceProbe()
        let tempDirProvider = tempDirProvider ?? FoundationTempDirectoryProvider()
        let timingRunner = timingRunner ?? AxolotyTimingRunner(
            commandRunner: configuredCommandRunner,
            environment: environment,
            planResolver: planResolution
        )
        let executor = AxolotyCheckExecutor(
            commandRunner: CanonicalTierCommandRunner(
                commandRunner: configuredCommandRunner,
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

        self.executableName = executableName
        self.environment = environment
        self.installSignalHandler = installSignalHandler && runnerConfiguration.installSignalHandler
        self.cancellation = invocationCancellation
        self.version = AxolotyVersion.current(environment: environment)
        self.checkCommands = AxolotyCheckCommands(
            commandRunner: configuredCommandRunner,
            contextValidator: contextValidator,
            outputMode: runnerConfiguration.outputMode,
            planResolver: planResolution,
            executor: executor
        )
        self.wireCommands = AxolotyWireCommands(
            environment: environment,
            outputMode: runnerConfiguration.outputMode,
            planResolver: planResolution,
            executor: executor
        )
        self.hardwareCommands = AxolotyHardwareCommands(
            commandRunner: configuredCommandRunner,
            contextValidator: contextValidator,
            deviceLeaseManager: deviceLeaseManager,
            fileSystem: fileSystem,
            environment: environment
        )
        self.serveCommands = AxolotyServeCommandRunner(
            executableName: executableName,
            environment: environment,
            fileSystem: fileSystem,
            processRunnerFactory: processRunnerFactory,
            portProbe: portProbe,
            tempDirProvider: tempDirProvider,
            cancellation: invocationCancellation
        )
        self.timingCommands = AxolotyTimingCommandRunner(
            executableName: executableName,
            timingRunner: timingRunner
        )
        self.repositoryValidationCommands = AxolotyRepositoryValidationCommands(
            repositoryRoot: normalizedRepositoryRoot
        )
        self.releaseCommands = AxolotyReleaseCommands(
            commandRunner: configuredCommandRunner,
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
        case .serve(let arguments):
            return serveCommands.run(arguments: arguments)
        case .timing(let arguments):
            return timingCommands.run(arguments: arguments)
        case .repositoryValidation(let arguments):
            return repositoryValidationCommands.run(arguments: arguments)
        case .hardware(let required, let device):
            return hardwareCommands.run(AxolotyHardwareCommand(required: required, device: device))
        case .wireBundle(let path):
            return wireCommands.run(.verifyBundle(path: path))
        case .testOne(let filter):
            return checkCommands.run(.testOne(filter: filter))
        case .testTier(let name, let ci):
            return checkCommands.run(.testTier(name: name, ci: ci))
        case .explain(let name, let ci):
            return checkCommands.run(.explain(tier: name, ci: ci))
        case .checkPlan:
            return checkCommands.run(.plan)
        case .check(let requested):
            return checkCommands.run(.check(requested: requested))
        case .build:
            return checkCommands.run(.build)
        case .testOffline:
            return checkCommands.run(.testOffline)
        case .testTooling:
            return checkCommands.run(.testTooling)
        case .verify(let ci):
            return checkCommands.run(.verify(ci: ci))
        case .integration:
            return checkCommands.run(.integration)
        case .wireCapture:
            return wireCommands.run(.capture)
        case .wireVerify:
            return wireCommands.run(.verifyFixtures)
        case .embeddedBuild:
            return checkCommands.run(.embeddedBuild)
        case .embeddedDoctor:
            return checkCommands.run(.embeddedDoctor)
        case .embeddedVerify:
            return checkCommands.run(.embeddedVerify)
        case .release(let command):
            return releaseCommands.run(command)
        }
    }
}
