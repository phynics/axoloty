// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import AxolotyTooling
import Foundation
import MCP
import Testing

@MainActor
private final class StatusSession: InspectorSession {
    var state: CommunicationState = .online

    func connect() async throws {}
    func communicationState() async -> CommunicationState { state }
    func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot> {
        AsyncStream { $0.finish() }
    }
    func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot> {
        AsyncStream { $0.finish() }
    }
    func discover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        AsyncStream { $0.finish() }
    }
    func stop() {}
}

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

@Test("Status reflects live online and offline communication state")
@MainActor
func statusReflectsCommunicationState() async throws {
    let session = StatusSession()
    let server = AxolotyMCPServer(session: session, namespace: "test")

    #expect((await server.collectStatus()).mqttConnected)

    session.state = .offline
    #expect(!(await server.collectStatus()).mqttConnected)
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

@Test("HTTP server repeatedly starts and stops without leaking its listener")
func httpServerRepeatedStartStop() async throws {
    let server = makeHTTPServer(port: 0)

    for _ in 0..<3 {
        let startTask = Task { try await server.start() }
        await server.waitUntilListening()
        try await withDeadline("HTTP server stop") {
            await server.stop()
            try await startTask.value
        }
    }
}

@Test("HTTP server releases its port for immediate rebinding")
func httpServerReleasesPortForRebinding() async throws {
    let firstServer = makeHTTPServer(port: 0)
    let firstStartTask = Task { try await firstServer.start() }
    await firstServer.waitUntilListening()
    let port = try #require(await firstServer.listeningPort())

    try await withDeadline("first HTTP server stop") {
        await firstServer.stop()
        try await firstStartTask.value
    }

    let reboundServer = makeHTTPServer(port: UInt16(port))
    let reboundStartTask = Task { try await reboundServer.start() }
    await reboundServer.waitUntilListening()
    #expect(await reboundServer.listeningPort() == port)

    try await withDeadline("rebound HTTP server stop") {
        await reboundServer.stop()
        try await reboundStartTask.value
    }
}

@Test("HTTP shutdown stops every active session")
func httpShutdownStopsActiveSessions() async throws {
    let server = makeHTTPServer(port: 0)
    let startTask = Task { try await server.start() }
    await server.waitUntilListening()

    let response = await server.handleHTTPRequest(try makeInitializeRequest())
    #expect(response.statusCode == 200)
    #expect(await server.activeSessionCount() == 1)

    try await withDeadline("HTTP shutdown with an active session") {
        await server.stop()
        try await startTask.value
    }
    #expect(await server.activeSessionCount() == 0)
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

@Test("MCP executable rejects invalid endpoint path with managed-service error")
func executableRejectsInvalidEndpointPathWithManagedServiceError() throws {
    let result = try runMCPExecutable(
        arguments: ["--transport", "http", "--path", "mcp"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError == "error: invalid endpoint path: mcp (must start with /)\n")
}

@Test("Direct and managed MCP path validation have identical outcomes")
func mcpPathValidationParityMatrix() throws {
    let cases: [(path: String, expectedError: AxolotyServeError?)] = [
        ("", .invalidPath("")),
        ("mcp", .invalidPath("mcp")),
        ("/api/mcp", nil),
    ]

    for testCase in cases {
        let directResult = try runMCPExecutableForPathValidation(
            arguments: ["--transport", "http", "--path=\(testCase.path)", "--connect-timeout", "30s"]
        )
        let managedResult = AxolotyServeParser().parse(
            arguments: ["mcp", "--transport", "http", "--path=\(testCase.path)"],
            environment: [:]
        )

        if let expectedError = testCase.expectedError {
            let expectedMessage = expectedError.userFriendlyMessage
            #expect(directResult == .rejected(
                exitCode: 64,
                standardError: "error: \(expectedMessage)\n"
            ))
            guard case .failure(let managedError) = managedResult else {
                Issue.record("managed validation accepted invalid path '\(testCase.path)'")
                continue
            }
            #expect(managedError == expectedError)
            #expect(managedError.userFriendlyMessage == expectedMessage)
        } else {
            #expect(directResult == .accepted)
            guard case .success(.mcp(let configuration)) = managedResult else {
                Issue.record("managed validation rejected valid path '\(testCase.path)'")
                continue
            }
            #expect(configuration.path == testCase.path)
        }
    }
}

@Test("MCP executable routes --path= through shared validation")
func executableRejectsEmptyEqualsPathWithManagedServiceError() throws {
    let result = try runMCPExecutable(arguments: ["--transport", "http", "--path="])

    #expect(result.exitCode == 64)
    #expect(result.standardError == "error: invalid endpoint path:  (must start with /)\n")
}

@Test("Managed MCP parser distinguishes missing from explicitly empty path")
func managedParserDistinguishesMissingAndEmptyPath() {
    let missing = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "http", "--path"],
        environment: [:]
    )
    let empty = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "http", "--path", ""],
        environment: [:]
    )

    #expect(missing == .failure(.missingValue("path")))
    #expect(empty == .failure(.invalidPath("")))
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

private enum MCPExecutablePathValidationResult: Equatable {
    case accepted
    case rejected(exitCode: Int32, standardError: String)
}

private func runMCPExecutableForPathValidation(
    arguments: [String]
) throws -> MCPExecutablePathValidationResult {
    let invocation = try makeMCPExecutableProcess(arguments: arguments)
    try invocation.process.run()

    let deadline = Date().addingTimeInterval(0.5)
    while invocation.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    if invocation.process.isRunning {
        invocation.process.terminate()
        invocation.process.waitUntilExit()
        return .accepted
    }

    let errorData = invocation.standardError.fileHandleForReading.readDataToEndOfFile()
    return .rejected(
        exitCode: invocation.process.terminationStatus,
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

private func runMCPExecutable(
    arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> (exitCode: Int32, standardError: String) {
    let invocation = try makeMCPExecutableProcess(arguments: arguments, environment: overrides)
    try invocation.process.run()
    invocation.process.waitUntilExit()
    let errorData = invocation.standardError.fileHandleForReading.readDataToEndOfFile()
    return (
        invocation.process.terminationStatus,
        String(decoding: errorData, as: UTF8.self)
    )
}

private func makeMCPExecutableProcess(
    arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> (process: Process, standardError: Pipe) {
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

    return (process, standardError)
}

private func makeHTTPServer(port: UInt16) -> MCPHTTPServer {
    MCPHTTPServer(
        host: "127.0.0.1",
        port: port,
        validationPipeline: StandardValidationPipeline(validators: []),
        serverFactory: { _, transport in
            let server = Server(
                name: "axoloty-mcp-lifecycle-test",
                version: "1.0.0",
                capabilities: .init()
            )
            try await server.start(transport: transport)
            return server
        }
    )
}

private func makeInitializeRequest() throws -> HTTPRequest {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "lifecycle-test", "version": "1.0.0"],
        ] as [String: Any],
    ])
    return HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ],
        body: body
    )
}

private struct TestDeadlineExceeded: Error {}

private func withDeadline(
    _ description: String,
    timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            Issue.record("Timed out waiting for \(description)")
            throw TestDeadlineExceeded()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}
