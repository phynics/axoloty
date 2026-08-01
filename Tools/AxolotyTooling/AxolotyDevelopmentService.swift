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

    public init(
        processRunnerFactory: @escaping @Sendable () -> any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        tempDirProvider: any AxolotyTempDirectoryProvider = FoundationTempDirectoryProvider(),
        mosquittoExecutable: String = "/usr/sbin/mosquitto",
        mcpExecutable: String = "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: Bool = true
    ) {
        self.processRunnerFactory = processRunnerFactory
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.tempDirProvider = tempDirProvider
        self.mosquittoExecutable = mosquittoExecutable
        self.mcpExecutable = mcpExecutable
        self.installSignalHandler = installSignalHandler
    }

    /// Runs the development stack and blocks until interrupted or a child exits.
    public func run(_ configuration: DevelopmentServiceConfiguration) -> Int32 {
        let output = configuration.output
        let mqttConfig = configuration.mqtt
        let mcpConfig = configuration.mcp

        guard fileSystem.exists(atPath: mosquittoExecutable) else {
            writeError("error: mosquitto executable not found at \(mosquittoExecutable)\n", output: output)
            return 69
        }
        guard fileSystem.exists(atPath: mcpExecutable) else {
            writeError("error: axoloty-mcp executable not found at \(mcpExecutable)\n", output: output)
            return 69
        }

        if !portProbe.isPortAvailable(host: mqttConfig.listenHost, port: mqttConfig.port) {
            writeError("error: port \(mqttConfig.port) is already in use\n", output: output)
            return 69
        }

        let tempDir: String
        do {
            tempDir = try tempDirProvider.createTempDirectory()
        } catch {
            writeError("error: unable to create temporary directory: \(error)\n", output: output)
            return 70
        }
        defer { tempDirProvider.removeDirectory(tempDir) }

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
            writeError("error: unable to write mosquitto config: \(error)\n", output: output)
            return 70
        }

        let mqttRunner = processRunnerFactory()
        do {
            try mqttRunner.start(ManagedProcessSpecification(
                executable: mosquittoExecutable,
                arguments: ["-c", configPath]
            ))
        } catch {
            writeError("error: unable to start mosquitto: \(error)\n", output: output)
            return 70
        }

        let mqttReady = portProbe.waitForTCP(
            host: mqttConfig.listenHost,
            port: mqttConfig.port,
            timeoutSeconds: 5.0
        )
        if !mqttReady {
            mqttRunner.forceKill()
            writeError("error: mosquitto did not become ready within 5 seconds\n", output: output)
            return 70
        }

        let mcpRunner = processRunnerFactory()
        do {
            try mcpRunner.start(ManagedProcessSpecification(
                executable: mcpExecutable,
                arguments: AxolotyMCPServiceRunner.buildArguments(from: mcpConfig)
            ))
        } catch {
            mqttRunner.forceKill()
            writeError("error: unable to start axoloty-mcp: \(error)\n", output: output)
            return 70
        }

        let mcpReady = portProbe.waitForTCP(
            host: mcpConfig.listenHost,
            port: mcpConfig.listenPort,
            timeoutSeconds: 10.0
        )
        if !mcpReady {
            mcpRunner.forceKill()
            mqttRunner.forceKill()
            writeError("error: axoloty-mcp did not become ready within 10 seconds\n", output: output)
            return 70
        }

        writeReadiness(mqtt: mqttConfig, mcp: mcpConfig, output: output)

        let signalHandler = installSignalHandler ? ServiceSignalHandler() : nil
        signalHandler?.install()
        defer { signalHandler?.uninstall() }

        while true {
            if signalHandler?.isInterrupted == true {
                terminateGracefully([mqttRunner, mcpRunner])
                return 130
            }

            if !mqttRunner.isRunning {
                let exit = mqttRunner.waitForExit()
                terminateGracefully([mcpRunner])
                if exit.exitCode != 0 {
                    writeError("error: mosquitto exited with code \(exit.exitCode)\n", output: output)
                }
                return exit.exitCode
            }

            if !mcpRunner.isRunning {
                let exit = mcpRunner.waitForExit()
                terminateGracefully([mqttRunner])
                if exit.exitCode != 0 {
                    writeError("error: axoloty-mcp exited with code \(exit.exitCode)\n", output: output)
                }
                return exit.exitCode
            }

            usleep(100_000)
        }
    }

    private func terminateGracefully(_ runners: [any AxolotyManagedProcessRunning]) {
        let deadline = Date().addingTimeInterval(5.0)
        for runner in runners { runner.terminate() }
        while Date() < deadline {
            if runners.allSatisfy({ !$0.isRunning }) { break }
            usleep(50_000)
        }
        for runner in runners where runner.isRunning {
            runner.forceKill()
            _ = runner.waitForExit()
        }
    }

    private func writeReadiness(mqtt: MQTTServiceConfiguration, mcp: MCPServiceConfiguration, output: ServeOutputMode) {
        let mqttURL = "mqtt://\(mqtt.listenHost):\(mqtt.port)"
        let mcpURL = "http://\(mcp.listenHost):\(mcp.listenPort)\(mcp.path)"
        switch output {
        case .human:
            FileHandle.standardError.write(Data(
                "DEV READY   MQTT \(mqttURL)\nMCP \(mcpURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = DevelopmentReadinessManifest(mqttURL: mqttURL, mcpURL: mcpURL)
            if let data = try? JSONEncoder().encode(manifest),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((json + "\n").utf8))
            }
        }
    }

    private func writeError(_ message: String, output: ServeOutputMode) {
        FileHandle.standardError.write(Data(message.utf8))
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
