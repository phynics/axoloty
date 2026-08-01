// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Generates Mosquitto configuration files for local development.
public struct MosquittoConfigGenerator: Sendable {
    public init() {}

    /// Generates a mosquitto.conf string for the given configuration.
    public func generate(listenHost: String, port: UInt16, logLevel: ServiceLogLevel) -> String {
        var lines: [String] = []
        lines.append("listener \(port) \(listenHost)")
        lines.append("allow_anonymous true")
        lines.append("persistence false")
        lines.append("log_dest stderr")
        if logLevel == .debug {
            lines.append("log_type all")
            lines.append("connection_messages true")
        } else if logLevel == .info {
            lines.append("connection_messages true")
        } else if logLevel == .warning {
            lines.append("log_type warning")
            lines.append("log_type error")
        } else {
            lines.append("log_type error")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Structured service readiness manifest for JSON output.
public struct ServiceReadinessManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let services: Services

    public struct Services: Codable, Sendable, Equatable {
        public let mqtt: MQTTService?
        public let mcp: MCPService?

        public struct MQTTService: Codable, Sendable, Equatable {
            public let url: String
        }

        public struct MCPService: Codable, Sendable, Equatable {
            public let transport: String
            public let url: String?
        }
    }

    public init(mqttURL: String) {
        self.schemaVersion = 1
        self.status = "ready"
        self.services = Services(mqtt: .init(url: mqttURL), mcp: nil)
    }
}

/// Runs the local Mosquitto broker service in the foreground.
public struct AxolotyMQTTServiceRunner: Sendable {
    private let processRunner: any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let fileSystem: any AxolotyFileSystem
    private let tempDirProvider: any AxolotyTempDirectoryProvider
    private let configGenerator: MosquittoConfigGenerator
    private let mosquittoExecutable: String
    private let installSignalHandler: Bool

    public init(
        processRunner: any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        tempDirProvider: any AxolotyTempDirectoryProvider = FoundationTempDirectoryProvider(),
        mosquittoExecutable: String = "/usr/sbin/mosquitto",
        installSignalHandler: Bool = true
    ) {
        self.processRunner = processRunner
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.tempDirProvider = tempDirProvider
        self.configGenerator = MosquittoConfigGenerator()
        self.mosquittoExecutable = mosquittoExecutable
        self.installSignalHandler = installSignalHandler
    }

    /// Runs the MQTT broker service and blocks until interrupted or the process exits.
    public func run(_ configuration: MQTTServiceConfiguration) -> Int32 {
        let output = configuration.output

        guard fileSystem.exists(atPath: mosquittoExecutable) else {
            writeError("error: mosquitto executable not found at \(mosquittoExecutable)\n", output: output)
            return 69
        }

        if !portProbe.isPortAvailable(host: configuration.listenHost, port: configuration.port) {
            writeError("error: port \(configuration.port) is already in use\n", output: output)
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
        let configContent = configGenerator.generate(
            listenHost: configuration.listenHost,
            port: configuration.port,
            logLevel: configuration.logLevel
        )
        do {
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        } catch {
            writeError("error: unable to write mosquitto config: \(error)\n", output: output)
            return 70
        }

        let spec = ManagedProcessSpecification(
            executable: mosquittoExecutable,
            arguments: ["-c", configPath]
        )

        do {
            try processRunner.start(spec)
        } catch {
            writeError("error: unable to start mosquitto: \(error)\n", output: output)
            return 70
        }

        let ready = portProbe.waitForTCP(
            host: configuration.listenHost,
            port: configuration.port,
            timeoutSeconds: 5.0
        )

        if !ready {
            processRunner.forceKill()
            writeError("error: mosquitto did not become ready within 5 seconds\n", output: output)
            return 70
        }

        let mqttURL = "mqtt://\(configuration.listenHost):\(configuration.port)"
        writeReadiness(mqttURL: mqttURL, output: output)

        let signalHandler = installSignalHandler ? ServiceSignalHandler() : nil
        signalHandler?.install()
        defer { signalHandler?.uninstall() }

        while true {
            if signalHandler?.isInterrupted == true {
                processRunner.terminate()
                let deadline = Date().addingTimeInterval(5.0)
                while Date() < deadline {
                    if !processRunner.isRunning { break }
                    usleep(50_000)
                }
                if processRunner.isRunning {
                    processRunner.forceKill()
                    _ = processRunner.waitForExit()
                }
                return 130
            }

            if !processRunner.isRunning {
                let exit = processRunner.waitForExit()
                if exit.exitCode != 0 {
                    writeError("error: mosquitto exited with code \(exit.exitCode)\n", output: output)
                    return 1
                }
                return 0
            }

            usleep(100_000)
        }
    }

    private func writeReadiness(mqttURL: String, output: ServeOutputMode) {
        switch output {
        case .human:
            FileHandle.standardError.write(Data(
                "MQTT READY  \(mqttURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = ServiceReadinessManifest(mqttURL: mqttURL)
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
