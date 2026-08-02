// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
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
