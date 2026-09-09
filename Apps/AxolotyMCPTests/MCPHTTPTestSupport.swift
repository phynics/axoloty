// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor HTTPServerStartState {
    private var failureMessage: String?

    func recordFailure(_ message: String) {
        failureMessage = message
    }

    func failure() -> String? {
        failureMessage
    }
}

func startHTTPServer(
    _ server: MCPHTTPServer,
    phase: String,
    timeout: Duration = .seconds(5)
) async throws -> Task<Void, Error> {
    let state = HTTPServerStartState()
    let startTask = Task {
        do {
            try await server.start()
        } catch {
            await state.recordFailure(String(reflecting: error))
            throw error
        }
    }

    do {
        let started = ContinuousClock.now
        try await withDeadline("\(phase) readiness", timeout: timeout) {
            while await server.listeningPort() == nil {
                if let failure = await state.failure() {
                    throw TestPhaseFailure(phase: phase, reason: failure)
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        print("[mcp-lifecycle-timing] phase=\(phase) readiness elapsed=\(ContinuousClock.now - started)")
        return startTask
    } catch {
        startTask.cancel()
        try? await withDeadline("\(phase) failure cleanup", timeout: .seconds(1)) {
            await server.stop()
        }
        throw error
    }
}

/// Stops a lifecycle test server and awaits its start task.
///
/// The stop deadline is generous on purpose (see #827): a stop closes the
/// channel, drains sessions, and joins a `System.coreCount`-sized NIO event
/// loop group. Measured stop cost is under 10ms idle and loaded, but joining
/// those threads under the parallel lane's CPU oversubscription legitimately
/// stalls for seconds on shared runners. A genuinely leaked listener never
/// finishes shutting down, so it still fails this deadline.
func stopHTTPServer(
    _ server: MCPHTTPServer,
    startTask: Task<Void, Error>,
    phase: String,
    timeout: Duration = .seconds(30)
) async throws {
    let started = ContinuousClock.now
    do {
        try await withDeadline(phase, timeout: timeout) {
            await server.stop()
            try await startTask.value
        }
    } catch {
        print("[mcp-lifecycle-timing] phase=\(phase) outcome=error elapsed=\(ContinuousClock.now - started)")
        throw error
    }
    print("[mcp-lifecycle-timing] phase=\(phase) outcome=completed elapsed=\(ContinuousClock.now - started)")
}

func makeHTTPServer(
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

func sendHTTPBody(
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

func makeInitializeRequest() throws -> HTTPRequest {
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

private struct TestPhaseFailure: LocalizedError {
    let phase: String
    let reason: String

    var errorDescription: String? {
        "MCP test phase '\(phase)' failed: \(reason)"
    }
}
