// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyMCP
import AxolotyInspectorCore
import AxolotyTooling
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

let helpText = """
Usage: axoloty-mcp [options]

Start an Axoloty MCP server using stdio or loopback HTTP.

Options:
  --transport MODE        Use stdio or http (default: stdio).
  --listen-host HOST      HTTP bind address (default: 127.0.0.1).
  --listen-port PORT      HTTP listen port (default: 8765).
  --path PATH             HTTP endpoint path (default: /mcp).
  --broker-host HOST      MQTT broker host (default: localhost).
  --broker-port PORT      MQTT broker port (default: 1883).
  --namespace NAMESPACE   Coaty namespace (default: -).
  --connect-timeout TIME  Broker readiness timeout (default: 10s).
  --help                  Show this help.
"""

if args.contains("--help") || args.contains("-h") {
    print(helpText)
    Foundation.exit(0)
}

var brokerHost = ProcessInfo.processInfo.environment["AXOLOTY_MQTT_HOST"] ?? "localhost"
var brokerPortRaw = ProcessInfo.processInfo.environment["AXOLOTY_MQTT_PORT"] ?? "1883"
var namespace = ProcessInfo.processInfo.environment["AXOLOTY_NAMESPACE"] ?? "-"

var transport = "stdio"
var listenHost = "127.0.0.1"
var listenPortRaw = ProcessInfo.processInfo.environment["AXOLOTY_MCP_PORT"] ?? "8765"
var mcpPath = "/mcp"
var connectTimeout: Duration = .seconds(10)

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
        brokerPortRaw = args[i + 1]
        i += 2
    case "--namespace":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --namespace requires a value\n".utf8))
            Foundation.exit(64)
        }
        namespace = args[i + 1]
        i += 2
    case "--connect-timeout":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --connect-timeout requires a value\n".utf8))
            Foundation.exit(64)
        }
        guard let value = InspectorDuration(rawValue: args[i + 1])?.value else {
            FileHandle.standardError.write(Data("error: invalid connect timeout: \(args[i + 1]) (use a positive duration such as 10s, 2m, or 1h; maximum 24h)\n".utf8))
            Foundation.exit(64)
        }
        connectTimeout = value
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
        listenPortRaw = args[i + 1]
        i += 2
    case "--path":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --path requires a value\n".utf8))
            Foundation.exit(64)
        }
        mcpPath = args[i + 1]
        i += 2
    case let argument where argument.hasPrefix("--path="):
        mcpPath = String(argument.dropFirst("--path=".count))
        i += 1
    default:
        FileHandle.standardError.write(Data("error: unknown argument: \(args[i])\n".utf8))
        Foundation.exit(64)
    }
}

guard let brokerPort = UInt16(brokerPortRaw), brokerPort > 0 else {
    FileHandle.standardError.write(Data("error: invalid broker port: \(brokerPortRaw) (must be 1–65535)\n".utf8))
    Foundation.exit(64)
}
guard let listenPort = UInt16(listenPortRaw), listenPort > 0 else {
    FileHandle.standardError.write(Data("error: invalid listen port: \(listenPortRaw) (must be 1–65535)\n".utf8))
    Foundation.exit(64)
}

if transport == "http" {
    switch MCPPathPolicy.validate(mcpPath) {
    case .success:
        break
    case .failure(let error):
        FileHandle.standardError.write(Data("error: \(error.userFriendlyMessage)\n".utf8))
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
    path: mcpPath,
    connectTimeout: connectTimeout
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
    path: String,
    connectTimeout: Duration
) async -> Int32 {
    do {
        let server = try AxolotyMCPServer(
            host: host,
            port: port,
            namespace: namespace,
            connectTimeout: connectTimeout
        )
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
