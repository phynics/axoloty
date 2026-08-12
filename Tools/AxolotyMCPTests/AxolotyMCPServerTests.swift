// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import AxolotyTooling
import Foundation
import Logging
import MCP
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        AsyncStream { _ in }
    }
    func stop() {}
}

private struct ForcedEncodingError: LocalizedError {
    let operation: String

    var errorDescription: String? { "forced \(operation) encoding failure" }
}

private func makeResolveResponse(
    objectId: String? = "obj-1",
    relatedObjectIds: [String] = []
) -> ResponseEventSnapshot {
    var fields: [String] = []
    if let objectId {
        fields.append("\"object\":{\"objectId\":\"\(objectId)\",\"coreType\":\"Identity\",\"objectType\":\"coaty.object.Identity\",\"name\":\"Agent\"}")
    }
    if !relatedObjectIds.isEmpty {
        let relatedJSON = relatedObjectIds.map { relatedId in
            "{\"objectId\":\"\(relatedId)\",\"coreType\":\"Identity\",\"objectType\":\"coaty.object.Identity\",\"name\":\"Related\"}"
        }.joined(separator: ",")
        fields.append("\"relatedObjects\":[\(relatedJSON)]")
    }
    return ResponseEventSnapshot(
        eventType: "resolve",
        sourceId: "src-1",
        correlationId: "corr-1",
        payload: "{\(fields.joined(separator: ","))}"
    )
}

@MainActor
private func discoverResultJSON(
    for responses: [ResponseEventSnapshot]
) async throws -> [String: Any] {
    let result = await AxolotyMCPServer.handleDiscoverObjects([
        "coreType": .string("Identity"),
        "timeoutMilliseconds": .int(1000),
    ]) { _ in
        AsyncThrowingStream { continuation in
            for response in responses {
                continuation.yield(response)
            }
        }
    }
    guard case let .text(text, _, _)? = result.content.first else {
        Issue.record("expected JSON text content")
        return [:]
    }
    let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(json["timedOut"] as? Bool == true)
    return json
}

@MainActor
private final class EncodingLogCapture {
    var message: String?
    var metadata: Logging.Logger.Metadata?

    func record(message: String, metadata: Logging.Logger.Metadata) {
        self.message = message
        self.metadata = metadata
    }
}

@MainActor
private final class ResponseStreamFixture {
    let stream: AsyncThrowingStream<ResponseEventSnapshot, Error>
    private let continuation: AsyncThrowingStream<ResponseEventSnapshot, Error>.Continuation

    init(response: ResponseEventSnapshot) {
        let (stream, continuation) = AsyncThrowingStream<ResponseEventSnapshot, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        continuation.yield(response)
    }

    func finish() {
        continuation.finish()
    }
}

private actor StreamTerminationProbe {
    private(set) var created = false
    private(set) var terminated = false

    func markCreated() {
        created = true
    }

    func markTerminated() {
        terminated = true
    }
}

private func makeResolveResponse(objectId: String, name: String) -> ResponseEventSnapshot {
    let payload = "{\"object\":{\"objectId\":\"\(objectId)\",\"coreType\":\"Identity\",\"objectType\":\"coaty.object.Identity\",\"name\":\"\(name)\"}}"
    return ResponseEventSnapshot(
        eventType: "resolve",
        sourceId: "source-1",
        correlationId: "correlation-1",
        payload: payload
    )
}

private struct ForcedTransportClose: LocalizedError {
    var errorDescription: String? { "forced transport close" }
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

@Test("Every MCP input schema is a valid object-root catalogue entry")
func objectInputSchemaCatalogueContract() throws {
    let expectedNames = [
        "axoloty_list_objects",
        "axoloty_get_object",
        "axoloty_discover_objects",
        "axoloty_server_status",
    ]
    let expectedPropertyTypes: [String: [String: String]] = [
        "axoloty_list_objects": [
            "coreType": "string",
            "objectType": "string",
            "objectId": "string",
            "sourceId": "string",
        ],
        "axoloty_get_object": ["objectId": "string"],
        "axoloty_discover_objects": [
            "coreType": "string",
            "objectType": "string",
            "objectId": "string",
            "timeoutMilliseconds": "integer",
        ],
        "axoloty_server_status": [:],
    ]

    let tools = AxolotyMCPServer.objectInputSchemaTools
    #expect(tools.map(\.name) == expectedNames)

    for tool in tools {
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["type"]?.stringValue == "object")
        let propertyTypes = try #require(expectedPropertyTypes[tool.name])

        if propertyTypes.isEmpty {
            #expect(tool.name == "axoloty_server_status")
            #expect(!schema.keys.contains("properties"))
        } else {
            let properties = try #require(schema["properties"]?.objectValue)
            #expect(Set(properties.keys) == Set(propertyTypes.keys))

            for (propertyName, expectedType) in propertyTypes {
                let propertySchema = try #require(properties[propertyName]?.objectValue)
                #expect(propertySchema["type"]?.stringValue == expectedType)
                #expect(propertySchema["description"]?.stringValue != nil)
            }
        }

        if tool.name == "axoloty_get_object" {
            let required = try #require(schema["required"]?.arrayValue)
            #expect(required.compactMap { $0.stringValue } == ["objectId"])
        } else {
            #expect(!schema.keys.contains("required"))
        }
    }
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
@Test("In-memory MCP transport reports encoding failure and logs its cause")
func directTransportReportsEncodingFailureAndLogsCause() async throws {
    let session = StatusSession()
    let logCapture = EncodingLogCapture()
    let responseEncoder = AxolotyMCPServer.ResponseEncoder(
        status: { _ in throw ForcedEncodingError(operation: "status") }
    )
    let mcpServer = AxolotyMCPServer(
        session: session,
        namespace: "test",
        responseEncoder: responseEncoder,
        encodingFailureLogger: { message, metadata in
            logCapture.record(message: message, metadata: metadata)
        }
    )
    let server = Server(
        name: "axoloty-mcp-direct-test",
        version: "1.0.0",
        capabilities: .init(tools: .init())
    )
    await mcpServer.registerHandlers(on: server)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

    do {
        try await server.start(transport: serverTransport)
        try await clientTransport.connect()

        let initializeRequest = Initialize.request(
            id: 1,
            .init(
                protocolVersion: Version.latest,
                capabilities: .init(),
                clientInfo: .init(name: "direct-test", version: "1.0")
            )
        )
        try await clientTransport.send(try JSONEncoder().encode(initializeRequest))
        _ = try await receiveMCPMessage(from: clientTransport)

        let callRequest = CallTool.request(
            id: 2,
            CallTool.Parameters(name: "axoloty_server_status", arguments: [:])
        )
        try await clientTransport.send(try JSONEncoder().encode(callRequest))
        let responseData = try await receiveMCPMessage(from: clientTransport)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Unable to encode MCP response; please retry the request.")
        #expect(logCapture.message == "Failed to encode MCP response")
        #expect(logCapture.metadata?["operation"] == .string("axoloty_server_status"))
        if case let .string(errorChain)? = logCapture.metadata?["error"] {
            #expect(errorChain.contains("ForcedEncodingError"))
            #expect(errorChain.contains("forced status encoding failure"))
        } else {
            Issue.record("expected wrapped encoding error metadata")
        }
    } catch {
        await server.stop()
        await clientTransport.disconnect()
        await serverTransport.disconnect()
        throw error
    }

    await server.stop()
    await clientTransport.disconnect()
    await serverTransport.disconnect()
}

@MainActor
@Test("Discover handler rejects invalid object ID before discovery")
func discoverHandlerRejectsInvalidObjectId() async {
    var discoveryCount = 0
    let result = await AxolotyMCPServer.handleDiscoverObjects(["objectId": .string("not-a-uuid")]) { _ in
        discoveryCount += 1
        return AsyncThrowingStream { $0.finish() }
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
        return AsyncThrowingStream { $0.finish() }
    }

    #expect(result.isError == true)
    #expect(discoveryCount == 0)
    guard case let .text(message, _, _)? = result.content.first else {
        Issue.record("expected text error content")
        return
    }
    #expect(message.contains("known core type"))
}

@MainActor
@Test("Discover handler preserves primary and related objects without duplicates")
func discoverHandlerPreservesAllResolveObjects() async throws {
    let json = try await discoverResultJSON(for: [
        makeResolveResponse(
            objectId: "primary-object",
            relatedObjectIds: ["related-object", "primary-object"]
        ),
    ])
    let objects = try #require(json["objects"] as? [[String: Any]])
    let objectIds = objects.compactMap { $0["objectId"] as? String }

    #expect(objectIds == ["primary-object", "related-object"].sorted())
    #expect(objects.count == 2)
}

@MainActor
@Test("Discover structured JSON handles related-only Resolve responses")
func discoverHandlerHandlesRelatedOnlyResolve() async throws {
    let json = try await discoverResultJSON(for: [
        makeResolveResponse(objectId: nil, relatedObjectIds: ["related-1", "related-2"]),
    ])
    let objects = try #require(json["objects"] as? [[String: Any]])

    #expect(objects.count == 2)
    #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["related-1", "related-2"])
}

@MainActor
@Test("Discover structured JSON handles mixed Resolve responses")
func discoverHandlerHandlesMixedResolve() async throws {
    let json = try await discoverResultJSON(for: [
        makeResolveResponse(objectId: "primary-1", relatedObjectIds: ["related-1"]),
    ])
    let objects = try #require(json["objects"] as? [[String: Any]])

    #expect(objects.count == 2)
    #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["primary-1", "related-1"])
}

@MainActor
@Test("Discover structured JSON deduplicates objects across Resolve responses")
func discoverHandlerDeduplicatesResolveObjectsById() async throws {
    let json = try await discoverResultJSON(for: [
        makeResolveResponse(objectId: "primary-1", relatedObjectIds: ["primary-1", "related-1"]),
        makeResolveResponse(objectId: "related-1", relatedObjectIds: ["related-2", "primary-1"]),
    ])
    let objects = try #require(json["objects"] as? [[String: Any]])

    #expect(objects.count == 3)
    #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["primary-1", "related-1", "related-2"])
}

@MainActor
@Test("Discover clean EOF reports a stream-exhausted MCP error")
func discoverCleanEOFIsNotReportedAsTimeout() async {
    let result = await AxolotyMCPServer.handleDiscoverObjects(["coreType": .string("Identity")]) { _ in
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    #expect(result.isError == true)
    guard case let .text(message, _, _)? = result.content.first else {
        Issue.record("expected text error content")
        return
    }
    #expect(message.contains("stream exhausted"))
    #expect(message.contains("clean EOF"))
    #expect(!message.contains("timed out"))
}

@MainActor
@Test("Discover deadline returns success with partial objects")
func discoverDeadlineReturnsPartialObjects() async throws {
    let streamFixture = ResponseStreamFixture(
        response: makeResolveResponse(objectId: "object-1", name: "Partial object")
    )
    let result = await AxolotyMCPServer.handleDiscoverObjects([
        "coreType": .string("Identity"),
        "timeoutMilliseconds": .int(1000),
    ]) { _ in streamFixture.stream }
    streamFixture.finish()

    #expect(result.isError == false)
    let text = try #require(result.content.first.flatMap { content -> String? in
        guard case let .text(value, _, _) = content else { return nil }
        return value
    })
    let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(json["timedOut"] as? Bool == true)
    let objects = try #require(json["objects"] as? [[String: Any]])
    #expect(objects.count == 1)
    #expect(objects.first?["objectId"] as? String == "object-1")
}

@MainActor
@Test("Discover abrupt transport close reports a distinct stream-exhausted MCP error")
func discoverAbruptCloseIsNotReportedAsTimeout() async throws {
    let result = await AxolotyMCPServer.handleDiscoverObjects(["coreType": .string("Identity")]) { _ in
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ForcedTransportClose())
        }
    }

    #expect(result.isError == true)
    let message = try #require(result.content.first.flatMap { content -> String? in
        guard case let .text(value, _, _) = content else { return nil }
        return value
    })
    #expect(message.contains("stream exhausted"))
    #expect(message.contains("abrupt transport close"))
    #expect(message.contains("forced transport close"))
    #expect(!message.contains("timed out"))
}

@MainActor
@Test("Production discovery adapter reports broker disconnect as abrupt stream exhaustion")
func productionDiscoveryAdapterReportsBrokerDisconnect() async throws {
    let session = StatusSession()
    let event = try InspectorDiscoveryRequest(coreType: "Identity").makeDiscoverEvent()
    let stream = await AxolotyMCPServer.discoveryResponseStream(session: session, event: event)
    let responseTask = Task {
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
    }

    session.state = .offline

    do {
        _ = try await responseTask.value
        Issue.record("expected the production adapter to throw when broker communication went offline")
    } catch let AxolotyError.runtime(code, reason) {
        #expect(code == .streamEnded)
        #expect(reason == "Broker communication transitioned offline during discovery")
    } catch {
        Issue.record("unexpected production adapter error: \(error)")
    }
}

@MainActor
@Test("Discover genuine timeout returns the unchanged success schema")
func discoverGenuineTimeoutIsSuccessful() async throws {
    let result = await AxolotyMCPServer.handleDiscoverObjects([
        "coreType": .string("Identity"),
        "timeoutMilliseconds": .int(1000),
    ]) { _ in
        AsyncThrowingStream { _ in }
    }

    #expect(result.isError == false)
    let text = try #require(result.content.first.flatMap { content -> String? in
        guard case let .text(value, _, _) = content else { return nil }
        return value
    })
    let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(Set(json.keys) == Set(["objects", "timedOut"]))
    #expect(json["timedOut"] as? Bool == true)
    #expect((json["objects"] as? [[String: Any]])?.isEmpty == true)
}

@MainActor
@Test("Discover cancellation terminates the response stream")
func discoverCancellationCleansUpResponseAndTimerTasks() async {
    let probe = StreamTerminationProbe()
    let operation = Task {
        await AxolotyMCPServer.handleDiscoverObjects(["coreType": .string("Identity")]) { _ in
            await probe.markCreated()
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in
                    Task {
                        await probe.markTerminated()
                    }
                }
            }
        }
    }

    while !(await probe.created) {
        await Task.yield()
    }
    operation.cancel()
    _ = await operation.value

    for _ in 0..<100 {
        if await probe.terminated {
            break
        }
        await Task.yield()
    }
    #expect(await probe.terminated)
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

@MainActor
@Test("HTTP transport reports response encoding failures as MCP errors")
func httpTransportReportsEncodingFailure() async throws {
    let session = StatusSession()
    let responseEncoder = AxolotyMCPServer.ResponseEncoder(
        status: { _ in throw ForcedEncodingError(operation: "status") }
    )
    let mcpServer = AxolotyMCPServer(
        session: session,
        namespace: "test",
        responseEncoder: responseEncoder
    )
    let httpServer = MCPHTTPServer(
        host: "127.0.0.1",
        port: 0,
        validationPipeline: StandardValidationPipeline(validators: []),
        serverFactory: { _, transport in
            let server = Server(
                name: "axoloty-mcp-encoding-test",
                version: "1.0.0",
                capabilities: .init()
            )
            await mcpServer.registerHandlers(on: server)
            try await server.start(transport: transport)
            return server
        }
    )
    let startTask = Task { try await httpServer.start() }
    await httpServer.waitUntilListening()
    let port = try #require(await httpServer.listeningPort())

    do {
        let initializeRequest = try makeInitializeRequest()
        let initializeBody = try #require(initializeRequest.body)
        let (_, initializeResponse) = try await sendHTTPBody(to: port, body: initializeBody)
        #expect(initializeResponse.statusCode == 200)
        let sessionID = try #require(initializeResponse.value(forHTTPHeaderField: "MCP-Session-Id"))

        let callBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "axoloty_server_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any])
        let (body, response) = try await sendHTTPBody(
            to: port,
            body: callBody,
            sessionID: sessionID
        )
        #expect(response.statusCode == 200)
        let wireResponse = String(bytes: body, encoding: .utf8) ?? ""
        let jsonLine: String = wireResponse
            .split(separator: "\n")
            .first(where: {
                guard $0.hasPrefix("data:") else { return false }
                return !$0.dropFirst("data:".count).allSatisfy { $0.isWhitespace }
            })
            .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
            ?? wireResponse
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any]
        )
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Unable to encode MCP response; please retry the request.")
    } catch {
        await httpServer.stop()
        _ = try? await startTask.value
        throw error
    }

    try await withDeadline("HTTP encoding failure shutdown") {
        await httpServer.stop()
        try await startTask.value
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

@Test("HTTP body cap accepts a body exactly at its configured boundary")
func httpBodyCapAcceptsConfiguredBoundary() async throws {
    let initializeRequest = try makeInitializeRequest()
    let body = try #require(initializeRequest.body)
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: body.count)
    let startTask = Task { try await server.start() }
    await server.waitUntilListening()
    let port = try #require(await server.listeningPort())

    do {
        let (_, response) = try await sendHTTPBody(to: port, body: body)
        #expect(response.statusCode == 200)
        #expect(await server.activeSessionCount() == 1)
    } catch {
        await server.stop()
        _ = try? await startTask.value
        throw error
    }

    try await withDeadline("HTTP boundary request shutdown") {
        await server.stop()
        try await startTask.value
    }
}

@Test("HTTP server rejects oversized Content-Length before buffering")
func httpBodyCapRejectsOversizedContentLength() async throws {
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: 8)
    let startTask = Task { try await server.start() }
    await server.waitUntilListening()
    let port = try #require(await server.listeningPort())

    do {
        let (_, response) = try await sendHTTPBody(
            to: port,
            body: Data(repeating: 0x78, count: 9)
        )
        #expect(response.statusCode == 413)
        #expect(await server.activeSessionCount() == 0)
    } catch {
        await server.stop()
        _ = try? await startTask.value
        throw error
    }

    try await withDeadline("HTTP oversized Content-Length request shutdown") {
        await server.stop()
        try await startTask.value
    }
}

@Test("HTTP server rejects oversized streamed body incrementally")
func httpBodyCapRejectsOversizedStreamedBody() async throws {
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: 8)
    let startTask = Task { try await server.start() }
    await server.waitUntilListening()
    let port = try #require(await server.listeningPort())

    do {
        let (_, response) = try await sendHTTPBody(
            to: port,
            body: Data(repeating: 0x78, count: 9),
            streamed: true
        )
        #expect(response.statusCode == 413)
        #expect(await server.activeSessionCount() == 0)
    } catch {
        await server.stop()
        _ = try? await startTask.value
        throw error
    }

    try await withDeadline("HTTP streamed request shutdown") {
        await server.stop()
        try await startTask.value
    }
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

private func makeHTTPServer(
    port: UInt16,
    maxRequestBodyBytes: Int = 1_048_576
) -> MCPHTTPServer {
    MCPHTTPServer(
        host: "127.0.0.1",
        port: port,
        maxRequestBodyBytes: maxRequestBodyBytes,
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

private func sendHTTPBody(
    to port: Int,
    body: Data,
    streamed: Bool = false,
    sessionID: String? = nil
) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
    }

    if streamed {
        request.httpBodyStream = InputStream(data: body)
    } else {
        request.httpBody = body
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
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

private func receiveMCPMessage(from transport: InMemoryTransport) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            for try await message in await transport.receive() {
                return message
            }
            throw TestDeadlineExceeded()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw TestDeadlineExceeded()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
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
