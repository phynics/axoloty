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
