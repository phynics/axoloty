// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Foundation
import Logging
import MCP

@MainActor
final class EncodingLogCapture {
    var message: String?
    var metadata: Logging.Logger.Metadata?

    func record(message: String, metadata: Logging.Logger.Metadata) {
        self.message = message
        self.metadata = metadata
    }
}

actor CancellationResistantGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

func receiveMCPMessage(from transport: InMemoryTransport) async throws -> Data {
    try await withDeadline("MCP in-memory response") {
        for try await message in await transport.receive() {
            return message
        }
        throw TestDeadlineExceeded(description: "MCP in-memory response stream ended")
    }
}
