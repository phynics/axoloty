// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs Mosquitto and ``axoloty-mcp`` as a supervised foreground development stack.
public struct AxolotyDevelopmentServiceRunner: Sendable {
    private let processRunnerFactory: @Sendable () -> any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let fileSystem: any AxolotyFileSystem
    private let tempDirProvider: any AxolotyTempDirectoryProvider
    private let mosquittoExecutable: String
    private let mcpExecutable: String
    private let installSignalHandler: Bool
    private let standardOutput: FileHandle
    private let standardError: FileHandle

    /// Creates a development service runner.
    ///
    /// JSON readiness is written to `standardOutput`; human readiness and diagnostics are
    /// written to `standardError`.
    ///
    /// - Parameters:
    ///   - processRunnerFactory: Factory used to create the supervised Mosquitto and MCP process runners.
    ///   - portProbe: Service probe used to check broker and MCP port availability and readiness.
    ///   - fileSystem: File-system abstraction used to locate the Mosquitto and MCP executables.
    ///   - tempDirProvider: Provider used to create and remove the temporary Mosquitto configuration directory.
    ///   - mosquittoExecutable: Path to the Mosquitto executable.
    ///   - mcpExecutable: Path to the `axoloty-mcp` executable.
    ///   - installSignalHandler: Whether to install the Ctrl-C signal handler.
    ///   - standardOutput: Destination for the JSON readiness manifest; defaults to process stdout.
    ///   - standardError: Destination for human readiness and structured diagnostics; defaults to process stderr.
    public init(
        processRunnerFactory: @escaping @Sendable () -> any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        tempDirProvider: any AxolotyTempDirectoryProvider = FoundationTempDirectoryProvider(),
        mosquittoExecutable: String = "/usr/sbin/mosquitto",
        mcpExecutable: String = "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: Bool = true,
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) {
        self.processRunnerFactory = processRunnerFactory
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.tempDirProvider = tempDirProvider
        self.mosquittoExecutable = mosquittoExecutable
        self.mcpExecutable = mcpExecutable
        self.installSignalHandler = installSignalHandler
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Runs the development stack and blocks until interrupted or a child exits.
    public func run(_ configuration: DevelopmentServiceConfiguration) -> Int32 {
        let output = configuration.output
        let diagnostics = ServiceDiagnosticLogger(output: output, standardError: standardError)
        let mqttConfig = configuration.mqtt
        let mcpConfig = configuration.mcp
        let processSupervisor = ManagedProcessSupervisor()
        let signalHandler = installSignalHandler
            ? ServiceSignalHandler(onInterrupt: { processSupervisor.requestTermination() })
            : nil
        signalHandler?.install()
        defer { signalHandler?.uninstall() }

        if signalHandler?.isInterrupted == true {
            return 130
        }

        guard fileSystem.exists(atPath: mosquittoExecutable) else {
            diagnostics.error("mosquitto executable not found at \(mosquittoExecutable)", metadata: ["executable": mosquittoExecutable])
            return 69
        }
        guard fileSystem.exists(atPath: mcpExecutable) else {
            diagnostics.error("axoloty-mcp executable not found at \(mcpExecutable)", metadata: ["executable": mcpExecutable])
            return 69
        }

        if !portProbe.isPortAvailable(host: mqttConfig.listenHost, port: mqttConfig.port) {
            diagnostics.error("port \(mqttConfig.port) is already in use", metadata: ["port": String(mqttConfig.port)])
            return 69
        }

        let tempDir: String
        do {
            tempDir = try tempDirProvider.createTempDirectory()
        } catch {
            diagnostics.error("unable to create temporary directory: \(error)", metadata: ["error": String(describing: error)])
            return 70
        }
        defer { tempDirProvider.removeDirectory(tempDir) }
        defer { processSupervisor.terminateAndWait() }

        let configPath = "\(tempDir)/mosquitto.conf"
        let configContent = MosquittoConfigGenerator().generate(
            listenHost: mqttConfig.listenHost,
            port: mqttConfig.port,
            logLevel: mqttConfig.logLevel
        )
        do {
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        } catch {
            diagnostics.error("unable to write mosquitto config: \(error)", metadata: ["error": String(describing: error), "path": configPath])
            return 70
        }

        if signalHandler?.isInterrupted == true {
            return 130
        }

        let mqttRunner = processRunnerFactory()
        do {
            try mqttRunner.start(ManagedProcessSpecification(
                executable: mosquittoExecutable,
                arguments: ["-c", configPath]
            ))
            processSupervisor.register(mqttRunner)
        } catch {
            if signalHandler?.isInterrupted == true {
                return 130
            }
            diagnostics.error("unable to start mosquitto: \(error)", metadata: ["error": String(describing: error), "executable": mosquittoExecutable])
            return 70
        }

        let mqttReady = portProbe.waitForTCP(
            host: mqttConfig.listenHost,
            port: mqttConfig.port,
            timeoutSeconds: 5.0
        )
        if signalHandler?.isInterrupted == true {
            return 130
        }
        if !mqttReady {
            mqttRunner.forceKill()
            diagnostics.error("mosquitto did not become ready within 5 seconds")
            return 70
        }

        if signalHandler?.isInterrupted == true {
            return 130
        }

        let mcpRunner = processRunnerFactory()
        do {
            try mcpRunner.start(ManagedProcessSpecification(
                executable: mcpExecutable,
                arguments: AxolotyMCPServiceRunner.buildArguments(from: mcpConfig)
            ))
            processSupervisor.register(mcpRunner)
        } catch {
            if signalHandler?.isInterrupted == true {
                return 130
            }
            mqttRunner.forceKill()
            diagnostics.error("unable to start axoloty-mcp: \(error)", metadata: ["error": String(describing: error), "executable": mcpExecutable])
            return 70
        }

        let mcpReadinessTimeout = AxolotyMCPServiceRunner.readinessTimeoutSeconds(for: mcpConfig)
        let mcpReady = portProbe.waitForTCP(
            host: mcpConfig.listenHost,
            port: mcpConfig.listenPort,
            timeoutSeconds: mcpReadinessTimeout
        )
        if signalHandler?.isInterrupted == true {
            return 130
        }
        if !mcpReady {
            mcpRunner.forceKill()
            mqttRunner.forceKill()
            diagnostics.error("axoloty-mcp did not become ready within \(mcpReadinessTimeout) seconds", metadata: ["timeoutSeconds": String(mcpReadinessTimeout)])
            return 70
        }

        writeReadiness(mqtt: mqttConfig, mcp: mcpConfig, output: output)

        while true {
            if signalHandler?.isInterrupted == true {
                return 130
            }

            if !mqttRunner.isRunning {
                let exit = mqttRunner.waitForExit()
                processSupervisor.requestTermination()
                if exit.exitCode != 0 {
                    diagnostics.error("mosquitto exited with code \(exit.exitCode)", metadata: ["exitCode": String(exit.exitCode)])
                }
                return exit.exitCode
            }

            if !mcpRunner.isRunning {
                let exit = mcpRunner.waitForExit()
                processSupervisor.requestTermination()
                if exit.exitCode != 0 {
                    diagnostics.error("axoloty-mcp exited with code \(exit.exitCode)", metadata: ["exitCode": String(exit.exitCode)])
                }
                return exit.exitCode
            }

            usleep(100_000)
        }
    }

    private func writeReadiness(mqtt: MQTTServiceConfiguration, mcp: MCPServiceConfiguration, output: ServeOutputMode) {
        let mqttURL = "mqtt://\(urlAuthorityHost(mqtt.listenHost)):\(mqtt.port)"
        let mcpURL = "http://\(urlAuthorityHost(mcp.listenHost)):\(mcp.listenPort)\(mcp.path)"
        switch output {
        case .human:
            standardError.write(Data(
                "DEV READY   MQTT \(mqttURL)\nMCP \(mcpURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = DevelopmentReadinessManifest(mqttURL: mqttURL, mcpURL: mcpURL)
            if let data = try? JSONEncoder().encode(manifest),
               let json = String(data: data, encoding: .utf8) {
                standardOutput.write(Data((json + "\n").utf8))
            }
        }
    }

}

private struct DevelopmentReadinessManifest: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let services: Services

    struct Services: Codable, Sendable {
        let mqtt: MQTT
        let mcp: MCP
    }

    struct MQTT: Codable, Sendable {
        let transport: String
        let url: String
    }

    struct MCP: Codable, Sendable {
        let transport: String
        let url: String
    }

    init(mqttURL: String, mcpURL: String) {
        self.schemaVersion = 1
        self.status = "ready"
        self.services = Services(
            mqtt: MQTT(transport: "mqtt", url: mqttURL),
            mcp: MCP(transport: "streamable-http", url: mcpURL)
        )
    }
}
