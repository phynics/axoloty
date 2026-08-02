// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Foundation
import MCP
import Testing

@Test("Discover tool advertises and consumes an integer timeout")
func discoverToolTimeoutContract() throws {
    let schema = try #require(AxolotyMCPServer.discoverObjectsTool.inputSchema.objectValue)
    let properties = try #require(schema["properties"]?.objectValue)
    let timeoutSchema = try #require(properties["timeoutMilliseconds"]?.objectValue)

    #expect(timeoutSchema["type"]?.stringValue == "integer")

    let request = AxolotyMCPServer.makeDiscoveryRequest(from: ["timeoutMilliseconds": .int(1234)])
    #expect(request.timeoutMilliseconds == 1234)
}

@Test("Discover timeout retains its documented clamp")
func discoverToolTimeoutClamp() {
    let belowMinimum = AxolotyMCPServer.makeDiscoveryRequest(from: ["timeoutMilliseconds": .int(999)])
    let aboveMaximum = AxolotyMCPServer.makeDiscoveryRequest(from: ["timeoutMilliseconds": .int(30_001)])

    #expect(belowMinimum.timeoutMilliseconds == 1000)
    #expect(aboveMaximum.timeoutMilliseconds == 30_000)
}

@MainActor
@Test("Discover handler rejects invalid object ID before discovery")
func discoverHandlerRejectsInvalidObjectId() async {
    var discoveryCount = 0
    let result = await AxolotyMCPServer.handleDiscoverObjects(["objectId": .string("not-a-uuid")]) { _ in
        discoveryCount += 1
        return AsyncStream { $0.finish() }
    }

    #expect(result.isError == true)
    #expect(discoveryCount == 0)
    guard case let .text(message, _, _)? = result.content.first else {
        Issue.record("expected text error content")
        return
    }
    #expect(message.contains("valid UUID"))
}

@MainActor
@Test("Discover handler rejects unknown core type before discovery")
func discoverHandlerRejectsUnknownCoreType() async {
    var discoveryCount = 0
    let result = await AxolotyMCPServer.handleDiscoverObjects(["coreType": .string("UnknownCoreType")]) { _ in
        discoveryCount += 1
        return AsyncStream { $0.finish() }
    }

    #expect(result.isError == true)
    #expect(discoveryCount == 0)
    guard case let .text(message, _, _)? = result.content.first else {
        Issue.record("expected text error content")
        return
    }
    #expect(message.contains("known core type"))
}

@Test("MCP server forwards broker readiness timeout to inspector runtime")
func brokerConnectionTimeoutIsApplied() {
    let configuration = AxolotyMCPServer.makeConnectionConfiguration(
        host: "broker.local",
        port: 1883,
        namespace: "test",
        connectTimeout: .seconds(37)
    )

    #expect(configuration.connectTimeout == .seconds(37))
}

@Test("MCP executable rejects invalid broker port")
func executableRejectsInvalidBrokerPort() throws {
    let result = try runMCPExecutable(arguments: ["--broker-port", "0"])

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid broker port"))
}

@Test("MCP executable rejects invalid listen port")
func executableRejectsInvalidListenPort() throws {
    let result = try runMCPExecutable(arguments: ["--listen-port", "70000"])

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid listen port"))
}

@Test("MCP executable rejects invalid connect timeout")
func executableRejectsInvalidConnectTimeout() throws {
    let result = try runMCPExecutable(
        arguments: ["--connect-timeout", "9223372036854775807m"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid connect timeout"))
}

@Test("MCP executable rejects invalid environment ports")
func executableRejectsInvalidEnvironmentPorts() throws {
    let brokerResult = try runMCPExecutable(
        arguments: [],
        environment: ["AXOLOTY_MQTT_PORT": "invalid"]
    )
    let listenResult = try runMCPExecutable(
        arguments: [],
        environment: ["AXOLOTY_MCP_PORT": "0"]
    )

    #expect(brokerResult.exitCode == 64)
    #expect(brokerResult.standardError.contains("invalid broker port"))
    #expect(listenResult.exitCode == 64)
    #expect(listenResult.standardError.contains("invalid listen port"))
}

@Test("MCP executable CLI port overrides invalid environment value")
func executableCLIOverridesInvalidEnvironmentPort() throws {
    let result = try runMCPExecutable(
        arguments: ["--broker-port", "1883", "--transport", "invalid"],
        environment: ["AXOLOTY_MQTT_PORT": "0"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("unknown transport"))
    #expect(!result.standardError.contains("invalid broker port"))
}

private func runMCPExecutable(
    arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> (exitCode: Int32, standardError: String) {
    let productsDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let executable = productsDirectory.appendingPathComponent("axoloty-mcp")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))

    let process = Process()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardError = standardError
    process.standardOutput = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["AXOLOTY_MQTT_PORT"] = "1883"
    environment["AXOLOTY_MCP_PORT"] = "8765"
    for (name, value) in overrides {
        environment[name] = value
    }
    process.environment = environment

    try process.run()
    process.waitUntilExit()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
}
