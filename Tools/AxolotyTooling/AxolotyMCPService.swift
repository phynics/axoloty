// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs the `axoloty-mcp` executable as a supervised child process.
public struct AxolotyMCPServiceRunner: Sendable {
    private let processRunner: any AxolotyManagedProcessRunning
    private let portProbe: any AxolotyServiceProbing
    private let fileSystem: any AxolotyFileSystem
    private let mcpExecutable: String
    private let installSignalHandler: Bool

    public init(
        processRunner: any AxolotyManagedProcessRunning,
        portProbe: any AxolotyServiceProbing,
        fileSystem: any AxolotyFileSystem,
        mcpExecutable: String = "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: Bool = true
    ) {
        self.processRunner = processRunner
        self.portProbe = portProbe
        self.fileSystem = fileSystem
        self.mcpExecutable = mcpExecutable
        self.installSignalHandler = installSignalHandler
    }

    public func run(_ configuration: MCPServiceConfiguration) -> Int32 {
        guard fileSystem.exists(atPath: mcpExecutable) else {
            FileHandle.standardError.write(Data(
                "error: axoloty-mcp executable not found at \(mcpExecutable)\n".utf8
            ))
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
        } catch {
            FileHandle.standardError.write(Data(
                "error: unable to start axoloty-mcp: \(error)\n".utf8
            ))
            return 70
        }

        if configuration.transport == .http {
            let readinessTimeout = Self.readinessTimeoutSeconds(for: configuration)
            let ready = portProbe.waitForTCP(
                host: configuration.listenHost,
                port: configuration.listenPort,
                timeoutSeconds: readinessTimeout
            )
            if !ready {
                processRunner.forceKill()
                FileHandle.standardError.write(Data(
                    "error: axoloty-mcp did not become ready within \(readinessTimeout) seconds\n".utf8
                ))
                return 70
            }

            let mcpURL = "http://\(urlAuthorityHost(configuration.listenHost)):\(configuration.listenPort)\(configuration.path)"
            writeReadiness(mcpURL: mcpURL, output: configuration.output)
        }

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
                    FileHandle.standardError.write(Data(
                        "error: axoloty-mcp exited with code \(exit.exitCode)\n".utf8
                    ))
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

    private func writeReadiness(mcpURL: String, output: ServeOutputMode) {
        switch output {
        case .human:
            FileHandle.standardError.write(Data(
                "MCP READY   \(mcpURL)\nPress Ctrl-C to stop.\n".utf8
            ))
        case .json:
            let manifest = MCPReadinessManifest(url: mcpURL)
            if let data = try? JSONEncoder().encode(manifest),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((json + "\n").utf8))
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
