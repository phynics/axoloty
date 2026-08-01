// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyMCP
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

var brokerHost = ProcessInfo.processInfo.environment["AXOLOTY_MQTT_HOST"] ?? "localhost"
var brokerPort = UInt16(ProcessInfo.processInfo.environment["AXOLOTY_MQTT_PORT"] ?? "1883") ?? 1883
var namespace = ProcessInfo.processInfo.environment["AXOLOTY_NAMESPACE"] ?? "-"

var transport = "stdio"
var listenHost = "127.0.0.1"
var listenPort: UInt16 = 8765
var mcpPath = "/mcp"

var i = 0
while i < args.count {
    switch args[i] {
    case "--broker-host":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --broker-host requires a value\n".utf8))
            Foundation.exit(64)
        }
        brokerHost = args[i + 1]
        i += 2
    case "--broker-port":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --broker-port requires a value\n".utf8))
            Foundation.exit(64)
        }
        brokerPort = UInt16(args[i + 1]) ?? 1883
        i += 2
    case "--namespace":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --namespace requires a value\n".utf8))
            Foundation.exit(64)
        }
        namespace = args[i + 1]
        i += 2
    case "--transport":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --transport requires a value\n".utf8))
            Foundation.exit(64)
        }
        transport = args[i + 1]
        i += 2
    case "--listen-host":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --listen-host requires a value\n".utf8))
            Foundation.exit(64)
        }
        listenHost = args[i + 1]
        i += 2
    case "--listen-port":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --listen-port requires a value\n".utf8))
            Foundation.exit(64)
        }
        listenPort = UInt16(args[i + 1]) ?? 8765
        i += 2
    case "--path":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --path requires a value\n".utf8))
            Foundation.exit(64)
        }
        mcpPath = args[i + 1]
        i += 2
    default:
        FileHandle.standardError.write(Data("error: unknown argument: \(args[i])\n".utf8))
        Foundation.exit(64)
    }
}

let exitCode = await runMCPServer(
    host: brokerHost,
    port: brokerPort,
    namespace: namespace,
    transport: transport,
    listenHost: listenHost,
    listenPort: listenPort,
    path: mcpPath
)
Foundation.exit(exitCode)

@MainActor
func runMCPServer(
    host: String,
    port: UInt16,
    namespace: String,
    transport: String,
    listenHost: String,
    listenPort: UInt16,
    path: String
) async -> Int32 {
    do {
        let server = try AxolotyMCPServer(host: host, port: port, namespace: namespace)
        switch transport {
        case "stdio":
            try await server.startStdio()
        case "http":
            try await server.startHTTP(listenHost: listenHost, listenPort: listenPort, path: path)
        default:
            FileHandle.standardError.write(Data("error: unknown transport: \(transport)\n".utf8))
            return 64
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 70
    }
}
