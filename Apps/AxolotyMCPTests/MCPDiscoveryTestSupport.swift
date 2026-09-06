// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import AxolotyInspectorRuntime
import Foundation
import MCP
import Testing

func makeResolveResponse(
    objectId: String? = "obj-1",
    relatedObjectIds: [String] = []
) -> InspectorResponseEvent {
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
    return InspectorResponseEvent(
        eventType: "resolve",
        sourceId: "src-1",
        correlationId: "corr-1",
        payload: "{\(fields.joined(separator: ","))}"
    )
}

@MainActor
func discoverResultJSON(
    for responses: [InspectorResponseEvent]
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
final class ResponseStreamFixture {
    let stream: AsyncThrowingStream<InspectorResponseEvent, Error>
    private let continuation: AsyncThrowingStream<InspectorResponseEvent, Error>.Continuation

    init(response: InspectorResponseEvent) {
        let (stream, continuation) = AsyncThrowingStream<InspectorResponseEvent, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        continuation.yield(response)
    }

    func finish() {
        continuation.finish()
    }
}

actor StreamTerminationProbe {
    private(set) var created = false
    private(set) var terminated = false

    func markCreated() {
        created = true
    }

    func markTerminated() {
        terminated = true
    }
}

func makeResolveResponse(objectId: String, name: String) -> InspectorResponseEvent {
    let payload = "{\"object\":{\"objectId\":\"\(objectId)\",\"coreType\":\"Identity\",\"objectType\":\"coaty.object.Identity\",\"name\":\"\(name)\"}}"
    return InspectorResponseEvent(
        eventType: "resolve",
        sourceId: "source-1",
        correlationId: "correlation-1",
        payload: payload
    )
}

struct ForcedTransportClose: LocalizedError {
    var errorDescription: String? { "forced transport close" }
}
