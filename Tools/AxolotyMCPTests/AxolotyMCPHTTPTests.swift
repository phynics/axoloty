// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test("HTTP server repeatedly starts and stops without leaking its listener")
func httpServerRepeatedStartStop() async throws {
    let server = makeHTTPServer(port: 0)

    for iteration in 0..<3 {
        let startTask = try await startHTTPServer(
            server,
            phase: "HTTP server start iteration \(iteration + 1)"
        )
        try await stopHTTPServer(
            server,
            startTask: startTask,
            phase: "HTTP server stop iteration \(iteration + 1)"
        )
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
    let startTask = try await startHTTPServer(httpServer, phase: "HTTP encoding server start")
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
        try? await stopHTTPServer(
            httpServer,
            startTask: startTask,
            phase: "HTTP encoding failure cleanup"
        )
        throw error
    }

    try await stopHTTPServer(
        httpServer,
        startTask: startTask,
        phase: "HTTP encoding failure shutdown"
    )
}

@Test("HTTP server releases its port for immediate rebinding")
func httpServerReleasesPortForRebinding() async throws {
    let firstServer = makeHTTPServer(port: 0)
    let firstStartTask = try await startHTTPServer(firstServer, phase: "first HTTP server start")
    let port = try #require(await firstServer.listeningPort())

    try await stopHTTPServer(
        firstServer,
        startTask: firstStartTask,
        phase: "first HTTP server stop"
    )

    let reboundServer = makeHTTPServer(port: UInt16(port))
    let reboundStartTask = try await startHTTPServer(reboundServer, phase: "rebound HTTP server start")
    #expect(await reboundServer.listeningPort() == port)

    try await stopHTTPServer(
        reboundServer,
        startTask: reboundStartTask,
        phase: "rebound HTTP server stop"
    )
}

@Test("HTTP shutdown stops every active session")
func httpShutdownStopsActiveSessions() async throws {
    let server = makeHTTPServer(port: 0)
    let startTask = try await startHTTPServer(server, phase: "active-session HTTP server start")

    let response = await server.handleHTTPRequest(try makeInitializeRequest())
    #expect(response.statusCode == 200)
    #expect(await server.activeSessionCount() == 1)

    try await stopHTTPServer(
        server,
        startTask: startTask,
        phase: "HTTP shutdown with an active session"
    )
    #expect(await server.activeSessionCount() == 0)
}

@Test("HTTP body cap accepts a body exactly at its configured boundary")
func httpBodyCapAcceptsConfiguredBoundary() async throws {
    let initializeRequest = try makeInitializeRequest()
    let body = try #require(initializeRequest.body)
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: body.count)
    let startTask = try await startHTTPServer(server, phase: "HTTP boundary server start")
    let port = try #require(await server.listeningPort())

    do {
        let (_, response) = try await sendHTTPBody(to: port, body: body)
        #expect(response.statusCode == 200)
        #expect(await server.activeSessionCount() == 1)
    } catch {
        try? await stopHTTPServer(
            server,
            startTask: startTask,
            phase: "HTTP boundary request cleanup"
        )
        throw error
    }

    try await stopHTTPServer(
        server,
        startTask: startTask,
        phase: "HTTP boundary request shutdown"
    )
}

@Test("HTTP server rejects oversized Content-Length before buffering")
func httpBodyCapRejectsOversizedContentLength() async throws {
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: 8)
    let startTask = try await startHTTPServer(server, phase: "HTTP Content-Length cap server start")
    let port = try #require(await server.listeningPort())

    do {
        let (_, response) = try await sendHTTPBody(
            to: port,
            body: Data(repeating: 0x78, count: 9)
        )
        #expect(response.statusCode == 413)
        #expect(await server.activeSessionCount() == 0)
    } catch {
        try? await stopHTTPServer(
            server,
            startTask: startTask,
            phase: "HTTP Content-Length cap cleanup"
        )
        throw error
    }

    try await stopHTTPServer(
        server,
        startTask: startTask,
        phase: "HTTP oversized Content-Length request shutdown"
    )
}

@Test("HTTP server rejects oversized streamed body incrementally")
func httpBodyCapRejectsOversizedStreamedBody() async throws {
    let server = makeHTTPServer(port: 0, maxRequestBodyBytes: 8)
    let startTask = try await startHTTPServer(server, phase: "HTTP streamed cap server start")
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
        try? await stopHTTPServer(
            server,
            startTask: startTask,
            phase: "HTTP streamed cap cleanup"
        )
        throw error
    }

    try await stopHTTPServer(
        server,
        startTask: startTask,
        phase: "HTTP streamed request shutdown"
    )
}
