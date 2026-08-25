// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs the `axoloty-mcp` executable as a supervised child process.
public struct AxolotyMCPServiceRunner: Sendable {
    private let processRunner: any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let fileSystem: any AxolotyFileSystem
    private let mcpExecutable: String
    private let installSignalHandler: Bool
    private let cancellation: AxolotyCommandCancellation?
    private let standardOutput: FileHandle
    private let standardError: FileHandle

    /// Creates an MCP service runner.
    ///
    /// JSON readiness is written to `standardOutput`; human readiness and diagnostics are
    /// written to `standardError`.
    ///
    /// - Parameters:
    ///   - processRunner: Process runner used to launch and supervise `axoloty-mcp`.
    ///   - portProbe: Service probe used to check the HTTP port and readiness.
    ///   - fileSystem: File-system abstraction used to locate the MCP executable.
    ///   - mcpExecutable: Path to the `axoloty-mcp` executable.
    ///   - installSignalHandler: Whether to install the Ctrl-C signal handler.
    ///   - standardOutput: Destination for the JSON readiness manifest; defaults to process stdout.
    ///   - standardError: Destination for human readiness and structured diagnostics; defaults to process stderr.
    public init(
        processRunner: any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        mcpExecutable: String = "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: Bool = true,
        cancellation: AxolotyCommandCancellation? = nil,
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) {
        self.processRunner = processRunner
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.mcpExecutable = mcpExecutable
        self.installSignalHandler = installSignalHandler
        self.cancellation = cancellation
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func run(_ configuration: MCPServiceConfiguration) -> Int32 {
        let diagnostics = ServiceDiagnosticLogger(
            output: configuration.output,
            standardError: standardError
        )
        let processSupervisor = ManagedProcessSupervisor()
        let cancellationObservation = cancellation?.observe { processSupervisor.requestTermination() }
        defer { cancellationObservation?.cancel() }
        let signalHandler = installSignalHandler
            ? ServiceSignalHandler(onInterrupt: { processSupervisor.requestTermination() })
            : nil
        signalHandler?.install()
        defer { signalHandler?.uninstall() }
        defer {
            let report = processSupervisor.terminateAndWait()
            for failure in report.failures {
                diagnostics.error(
                    "managed MCP process cleanup failed",
                    metadata: [
                        "pid": failure.processIdentifier.map(String.init) ?? "unknown",
                        "process": failure.processDescription,
                        "phase": failure.phase,
                    ]
                )
            }
        }

        if isInterrupted(signalHandler) {
            return 130
        }

        guard fileSystem.exists(atPath: mcpExecutable) else {
            diagnostics.error(
                "axoloty-mcp executable not found at \(mcpExecutable)",
                metadata: ["executable": mcpExecutable]
            )
            return 69
        }

        let args = Self.buildArguments(from: configuration)
        let spec = ManagedProcessSpecification(
            executable: mcpExecutable,
            arguments: args,
            environment: nil
        )

        do {
            try processRunner.start(spec)
            processSupervisor.register(processRunner)
        } catch {
            if isInterrupted(signalHandler) {
                return 130
            }
            diagnostics.error(
                "unable to start axoloty-mcp: \(error)",
                metadata: ["error": String(describing: error), "executable": mcpExecutable]
            )
            return 70
        }

        if configuration.transport == .http {
            let readinessTimeout = Self.readinessTimeoutSeconds(for: configuration)
            let ready = portProbe.waitForTCP(
                host: configuration.listenHost,
                port: configuration.listenPort,
                timeoutSeconds: readinessTimeout
            )
            if isInterrupted(signalHandler) {
                return 130
            }
            if !ready {
                processRunner.forceKill()
                diagnostics.error(
                    "axoloty-mcp did not become ready within \(readinessTimeout) seconds",
                    metadata: ["timeoutSeconds": String(readinessTimeout)]
                )
                return 70
            }

            let mcpURL = "http://\(urlAuthorityHost(configuration.listenHost)):\(configuration.listenPort)\(configuration.path)"
            writeReadiness(mcpURL: mcpURL, output: configuration.output)
        }

        while true {
            if isInterrupted(signalHandler) {
                return 130
            }

            if !processRunner.isRunning {
                guard let exit = processRunner.waitForExit(timeoutSeconds: 1) else {
                    diagnostics.error("axoloty-mcp exit state was not reaped", metadata: ["process": processRunner.processDescription])
                    return 70
                }
                if exit.exitCode != 0 {
                    diagnostics.error(
                        "axoloty-mcp exited with code \(exit.exitCode)",
                        metadata: ["exitCode": String(exit.exitCode)]
                    )
                    return 1
                }
                return 0
            }

            usleep(100_000)
        }
    }

    static func buildArguments(from config: MCPServiceConfiguration) -> [String] {
        var args: [String] = [
            "--transport", config.transport.rawValue,
            "--broker-host", config.brokerHost,
            "--broker-port", String(config.brokerPort),
            "--namespace", config.namespace,
            "--connect-timeout", config.connectTimeout,
        ]
        if config.transport == .http {
            args.append(contentsOf: [
                "--listen-host", config.listenHost,
                "--listen-port", String(config.listenPort),
                "--path", config.path,
            ])
        }
        return args
    }

    static func readinessTimeoutSeconds(for config: MCPServiceConfiguration) -> Double {
        let brokerTimeout = AxolotyServeParser.connectTimeoutSeconds(config.connectTimeout) ?? 10
        return brokerTimeout + 5
    }

    private func isInterrupted(_ signalHandler: ServiceSignalHandling?) -> Bool {
        signalHandler?.isInterrupted == true || cancellation?.isCancelled == true
    }

    private func writeReadiness(mcpURL: String, output: ServeOutputMode) {
        switch output {
        case .human:
            standardError.write(Data(
                "MCP READY   \(mcpURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = MCPReadinessManifest(url: mcpURL)
            if let data = try? JSONEncoder().encode(manifest),
               let json = String(data: data, encoding: .utf8) {
                standardOutput.write(Data((json + "\n").utf8))
            }
        }
    }
}

private struct MCPReadinessManifest: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let services: Services

    struct Services: Codable, Sendable {
        let mcp: MCP
    }

    struct MCP: Codable, Sendable {
        let transport: String
        let url: String
    }

    init(url: String) {
        self.schemaVersion = 1
        self.status = "ready"
        self.services = Services(mcp: MCP(transport: "streamable-http", url: url))
    }
}
