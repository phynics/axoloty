// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyMCP
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

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
func discoverHandlerRejectsUnknownInspectorCoreType() async {
    var discoveryCount = 0
    let result = await AxolotyMCPServer.handleDiscoverObjects(["coreType": .string("UnknownInspectorCoreType")]) { _ in
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
    let event = try InspectorDiscoveryRequest(coreType: "Identity").makeInspectorDiscoverRequest()
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

    do {
        try await waitForCondition("discover response stream creation") {
            await probe.created
        }
    } catch {
        operation.cancel()
        Issue.record("discover cancellation setup failed: \(error)")
        return
    }
    operation.cancel()

    do {
        try await withDeadline("discover cancellation operation") {
            _ = await operation.value
        }
        try await waitForCondition("discover response stream termination") {
            await probe.terminated
        }
    } catch {
        Issue.record("discover cancellation cleanup failed: \(error)")
    }
}
