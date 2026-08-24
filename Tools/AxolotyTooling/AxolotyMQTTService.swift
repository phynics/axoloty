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

enum ServiceDiagnosticLevel: String, Codable, Sendable {
    case warning
    case error
}

struct ServiceDiagnosticRecord: Codable, Sendable, Equatable {
    let level: ServiceDiagnosticLevel
    let message: String
    let metadata: [String: String]
}

// The tooling target owns this diagnostic shape instead of depending on a
// product logger. Tests can inject stderr and assert the structured output.
struct ServiceDiagnosticLogger: Sendable {
    private let output: ServeOutputMode
    private let standardError: FileHandle

    init(output: ServeOutputMode, standardError: FileHandle) {
        self.output = output
        self.standardError = standardError
    }

    func warning(_ message: String, metadata: [String: String] = [:]) {
        write(ServiceDiagnosticRecord(level: .warning, message: message, metadata: metadata))
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        write(ServiceDiagnosticRecord(level: .error, message: message, metadata: metadata))
    }

    private func write(_ record: ServiceDiagnosticRecord) {
        switch output {
        case .human:
            standardError.write(Data("\(record.level.rawValue): \(record.message)\n".utf8))
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(record) else { return }
            standardError.write(data)
            standardError.write(Data("\n".utf8))
        }
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
    private let cancellation: AxolotyCommandCancellation?
    private let standardOutput: FileHandle
    private let standardError: FileHandle

    /// Creates an MQTT service runner.
    ///
    /// JSON readiness is written to `standardOutput`; human readiness and diagnostics are
    /// written to `standardError`.
    ///
    /// - Parameters:
    ///   - processRunner: Process runner used to launch and supervise Mosquitto.
    ///   - portProbe: Service probe used to check broker port availability and readiness.
    ///   - fileSystem: File-system abstraction used to locate the Mosquitto executable.
    ///   - tempDirProvider: Provider used to create and remove the temporary configuration directory.
    ///   - mosquittoExecutable: Path to the Mosquitto executable.
    ///   - installSignalHandler: Whether to install the Ctrl-C signal handler.
    ///   - standardOutput: Destination for the JSON readiness manifest; defaults to process stdout.
    ///   - standardError: Destination for human readiness and structured diagnostics; defaults to process stderr.
    public init(
        processRunner: any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        tempDirProvider: any AxolotyTempDirectoryProvider = FoundationTempDirectoryProvider(),
        mosquittoExecutable: String = "/usr/sbin/mosquitto",
        installSignalHandler: Bool = true,
        cancellation: AxolotyCommandCancellation? = nil,
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) {
        self.processRunner = processRunner
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.tempDirProvider = tempDirProvider
        self.configGenerator = MosquittoConfigGenerator()
        self.mosquittoExecutable = mosquittoExecutable
        self.installSignalHandler = installSignalHandler
        self.cancellation = cancellation
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Runs the MQTT broker service and blocks until interrupted or the process exits.
    public func run(_ configuration: MQTTServiceConfiguration) -> Int32 {
        let output = configuration.output
        let diagnostics = ServiceDiagnosticLogger(output: output, standardError: standardError)
        let processSupervisor = ManagedProcessSupervisor()
        let cancellationObservation = cancellation?.observe { processSupervisor.requestTermination() }
        defer { cancellationObservation?.cancel() }
        let signalHandler = installSignalHandler
            ? ServiceSignalHandler(onInterrupt: { processSupervisor.requestTermination() })
            : nil
        signalHandler?.install()
        defer { signalHandler?.uninstall() }

        if isInterrupted(signalHandler) {
            return 130
        }

        guard fileSystem.exists(atPath: mosquittoExecutable) else {
            diagnostics.error(
                "mosquitto executable not found at \(mosquittoExecutable)",
                metadata: ["executable": mosquittoExecutable]
            )
            return 69
        }

        if !portProbe.isPortAvailable(host: configuration.listenHost, port: configuration.port) {
            diagnostics.error(
                "port \(configuration.port) is already in use",
                metadata: ["port": String(configuration.port)]
            )
            return 69
        }

        let tempDir: String
        do {
            tempDir = try tempDirProvider.createTempDirectory()
        } catch {
            diagnostics.error(
                "unable to create temporary directory: \(error)",
                metadata: ["error": String(describing: error)]
            )
            return 70
        }

        defer { tempDirProvider.removeDirectory(tempDir) }
        defer { processSupervisor.terminateAndWait() }

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
            diagnostics.error(
                "unable to write mosquitto config: \(error)",
                metadata: ["error": String(describing: error), "path": configPath]
            )
            return 70
        }

        if isInterrupted(signalHandler) {
            return 130
        }

        let spec = ManagedProcessSpecification(
            executable: mosquittoExecutable,
            arguments: ["-c", configPath]
        )

        do {
            try processRunner.start(spec)
            processSupervisor.register(processRunner)
        } catch {
            if isInterrupted(signalHandler) {
                return 130
            }
            diagnostics.error(
                "unable to start mosquitto: \(error)",
                metadata: ["error": String(describing: error), "executable": mosquittoExecutable]
            )
            return 70
        }

        let ready = portProbe.waitForTCP(
            host: configuration.listenHost,
            port: configuration.port,
            timeoutSeconds: 5.0
        )

        if isInterrupted(signalHandler) {
            return 130
        }
        if !ready {
            processRunner.forceKill()
            diagnostics.error("mosquitto did not become ready within 5 seconds")
            return 70
        }

        let mqttURL = "mqtt://\(urlAuthorityHost(configuration.listenHost)):\(configuration.port)"
        writeReadiness(mqttURL: mqttURL, output: output)

        while true {
            if isInterrupted(signalHandler) {
                return 130
            }

            if !processRunner.isRunning {
                let exit = processRunner.waitForExit()
                if exit.exitCode != 0 {
                    diagnostics.error(
                        "mosquitto exited with code \(exit.exitCode)",
                        metadata: ["exitCode": String(exit.exitCode)]
                    )
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
            standardError.write(Data(
                "MQTT READY  \(mqttURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = ServiceReadinessManifest(mqttURL: mqttURL)
            if let data = try? JSONEncoder().encode(manifest),
               let json = String(data: data, encoding: .utf8) {
                standardOutput.write(Data((json + "\n").utf8))
            }
        }
    }

    private func isInterrupted(_ signalHandler: ServiceSignalHandling?) -> Bool {
        signalHandler?.isInterrupted == true || cancellation?.isCancelled == true
    }

}
