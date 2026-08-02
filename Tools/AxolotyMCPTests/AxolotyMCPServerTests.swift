// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
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
