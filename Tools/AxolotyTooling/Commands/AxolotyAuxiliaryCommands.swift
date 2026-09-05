// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Executes the existing serve parser and service runners from the CLI seam.
struct AxolotyServeCommandRunner: Sendable {
    private let executableName: String
    private let environment: [String: String]
    private let fileSystem: any AxolotyFileSystem
    private let processRunnerFactory: @Sendable () -> any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let tempDirProvider: any AxolotyTempDirectoryProvider
    private let cancellation: AxolotyCommandCancellation

    init(
        executableName: String,
        environment: [String: String],
        fileSystem: any AxolotyFileSystem,
        processRunnerFactory: @escaping @Sendable () -> any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        tempDirProvider: any AxolotyTempDirectoryProvider,
        cancellation: AxolotyCommandCancellation
    ) {
        self.executableName = executableName
        self.environment = environment
        self.fileSystem = fileSystem
        self.processRunnerFactory = processRunnerFactory
        self.portProbe = portProbe
        self.tempDirProvider = tempDirProvider
        self.cancellation = cancellation
    }

    /// Parses and executes one serve command.
    func run(arguments: [String]) -> AxolotyCommandResult {
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
                return AxolotyCommandResult(exitCode: runner.run(config))
            case .mcp(let config):
                let runner = AxolotyMCPServiceRunner(
                    processRunner: processRunnerFactory(),
                    portProbe: portProbe,
                    fileSystem: fileSystem,
                    mcpExecutable: environment["AXOLOTY_MCP_EXECUTABLE"] ?? "/opt/axoloty/bin/axoloty-mcp",
                    installSignalHandler: false,
                    cancellation: cancellation
                )
                return AxolotyCommandResult(exitCode: runner.run(config))
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
                return AxolotyCommandResult(exitCode: runner.run(config))
            }
        case .failure(let error):
            return AxolotyCommandResult(
                standardError: "error: \(error.userFriendlyMessage)\n",
                exitCode: 64
            )
        }
    }
}

/// Parses and executes the existing timing command without changing its runner.
struct AxolotyTimingCommandRunner: Sendable {
    private let executableName: String
    private let timingRunner: AxolotyTimingRunner

    init(executableName: String, timingRunner: AxolotyTimingRunner) {
        self.executableName = executableName
        self.timingRunner = timingRunner
    }

    /// Parses and executes one timing command.
    func run(arguments: [String]) -> AxolotyCommandResult {
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
            return try AxolotyCommandFamilySupport.jsonResult(report, exitCode: report.exitCode)
        } catch {
            let diagnostic = AxolotyTimingOutputParser.boundedDiagnostic(String(reflecting: error))
                ?? "unknown encoding error"
            return AxolotyCommandResult(
                standardError: "error: unable to encode timing report: \(diagnostic)\n",
                exitCode: 70
            )
        }
    }
}

/// Parses and executes repository-authority validation output.
struct AxolotyRepositoryValidationCommands: Sendable {
    private let repositoryRoot: URL

    init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    /// Parses and executes one repository validation command.
    func run(arguments: [String]) -> AxolotyCommandResult {
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
            return (try? AxolotyCommandFamilySupport.jsonResult(report, exitCode: report.status == "passed" ? 0 : 1))
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
}
