// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import AxolotyWire
import Foundation
import Testing

/// Focused tests for the public discover-responder registration added in #441.
///
/// Reuses the transport seam from `EventHubTransportTests.swift`
/// (`makeManager`, `bringOnline`, `FakeCommunicationClient`, `emitDiscover`,
/// `topicEventType`, `topicCorrelationId`).
@MainActor
@Suite
struct DiscoverResponderRegistrationTests {

    /// A Discover request with a correlation id is delivered to the handler;
    /// resolving it publishes exactly one message on the correlated Resolve
    /// topic with the manager's source id.
    @Test
    func correlatedRequestResolvesExactlyOnce() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let received = DiscoverRequestStore()
        let responder = await manager.registerDiscoverResponder { request in
            await received.append(request)
            try request.resolve(object: Self.sampleObject)
        }
        defer { responder.cancel() }

        let snapshot = DiscoverEventSnapshot(
            sourceId: "caller",
            correlationId: "corr-1",
            objectTypes: ["com.example.Temperature"]
        )
        await client.emitDiscover(snapshot)

        // Wait for the handler to run and the Resolve publication to appear.
        try await waitUntil("request delivered") {
            await received.count == 1
        }
        let request = try #require(await received.first)
        #expect(request.snapshot.correlationId == "corr-1")
        #expect(request.correlationId == "corr-1")

        try await waitUntil("Resolve published") {
            client.publishedTopics.contains { topicEventType($0) == .resolve }
        }
        let resolveTopic = try #require(
            client.publishedTopics.first { topicEventType($0) == .resolve }
        )
        #expect(topicCorrelationId(resolveTopic) == "corr-1")

        // The source id is carried on the topic (level 4), not the JSON body.
        let sourceBytes = Array(resolveTopic.utf8)
        let topicSourceId = sourceBytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count).sourceIdLevel?.asString()
        }
        #expect(topicSourceId == manager.identity.objectId.string)

        // The published payload carries the resolved object.
        let publication = try #require(
            client.publishedMessages.first {
                topicEventType($0.topic) == .resolve
            }
        )
        let event = try JSONDecoder().decode(ResolveEvent.self, from: Data(publication.message.utf8))
        let resolved = try #require(event.data.object)
        #expect(resolved.objectId == Self.sampleObject.objectId)
        #expect(resolved.objectType == "com.example.Temperature")
    }

    /// A handler that declines (returns without resolving) publishes nothing.
    @Test
    func declinedRequestPublishesNothing() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let responder = await manager.registerDiscoverResponder { _ in
            // decline: no resolve call.
        }
        defer { responder.cancel() }

        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-1")
        )
        try await Task.sleep(for: .milliseconds(75))
        #expect(client.publishedTopics.filter { topicEventType($0) == .resolve }.isEmpty)
    }

    /// A Discover without a correlation id never invokes the handler.
    @Test
    func correlationLessDiscoverNeverInvokesHandler() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let received = DiscoverRequestStore()
        let responder = await manager.registerDiscoverResponder { request in
            await received.append(request)
        }
        defer { responder.cancel() }

        await client.emitDiscover(DiscoverEventSnapshot(sourceId: "caller"))
        try await Task.sleep(for: .milliseconds(75))
        #expect(await received.count == 0)
        #expect(client.publishedTopics.filter { topicEventType($0) == .resolve }.isEmpty)
    }

    /// Multiple Resolve calls for one request are permitted.
    @Test
    func multipleResolvesPerRequestArePermitted() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let responder = await manager.registerDiscoverResponder { request in
            try request.resolve(object: Self.sampleObject)
            try request.resolve(object: Self.sampleObject)
        }
        defer { responder.cancel() }

        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-multi")
        )
        try await waitUntil("two Resolve publications") {
            client.publishedTopics.filter { topicEventType($0) == .resolve }.count == 2
        }
        let resolveTopics = client.publishedTopics.filter { topicEventType($0) == .resolve }
        #expect(resolveTopics.allSatisfy { topicCorrelationId($0) == "corr-multi" })
    }

    /// An encoding failure (a related-objects-only Resolve, which the host
    /// encoder rejects) throws and publishes nothing.
    @Test
    func encodingFailureThrowsAndPublishesNothing() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        var capture: Error?
        let responder = await manager.registerDiscoverResponder { request in
            // A related-only ResolveEvent (no primary object) is rejected by
            // the host encoder ("Resolve requires an object").
            let event = ResolveEvent.with(relatedObjects: [Self.sampleObject])
            do {
                try request.resolve(event)
            } catch {
                capture = error
            }
        }
        defer { responder.cancel() }

        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-enc")
        )
        try await waitUntil("handler ran and captured failure") { capture != nil }
        let failure = try #require(capture)
        #expect(failure is AxolotyError)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.publishedTopics.filter { topicEventType($0) == .resolve }.isEmpty)
    }

    /// Cancelling the registration invalidates already-created requests:
    /// a previously retained request's resolve() throws and publishes nothing.
    @Test
    func cancellationInvalidatesRetainedRequest() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        var retainedRequest: DiscoverRequest?
        let responder = await manager.registerDiscoverResponder { request in
            retainedRequest = request
        }
        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-retain")
        )
        try await waitUntil("request retained") { retainedRequest != nil }

        responder.cancel()
        #expect(responder.isCancelled)

        let request = try #require(retainedRequest)
        #expect(throws: AxolotyError.self) {
            try request.resolve(object: Self.sampleObject)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.publishedTopics.filter { topicEventType($0) == .resolve }.isEmpty)
    }

    /// Resolving while the transport is offline throws and does not enter the
    /// deferred publication queue.
    @Test
    func offlineResolutionThrowsAndIsNotDeferred() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let responder = await manager.registerDiscoverResponder { request in
            try request.resolve(object: Self.sampleObject)
        }
        defer { responder.cancel() }

        // Offline after registration, then emit a request.
        await client.simulateState(.offline)
        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-off")
        )
        try await waitUntil("offline handler ran") { true }

        // Emitting offline reaches the handler; resolving must throw. The
        // throwing path publishes nothing to the transport (and never enters
        // the deferred queue, because the throw happens before `client.publish`).
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.publishedTopics.filter { topicEventType($0) == .resolve }.isEmpty)
    }

    /// Manager shutdown cancels every registration.
    @Test
    func managerShutdownCancelsRegistration() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        let responder = await manager.registerDiscoverResponder { _ in }
        manager.stop()
        #expect(responder.isCancelled)
    }

    /// A thrown handler error is logged and does not stop later requests.
    @Test
    func handlerErrorDoesNotStopLaterRequests() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)

        var invocations = 0
        let responder = await manager.registerDiscoverResponder { request in
            invocations += 1
            if invocations == 1 {
                throw AxolotyError.runtime(code: .notRegistered, reason: "boom")
            }
            try request.resolve(object: Self.sampleObject)
        }
        defer { responder.cancel() }

        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-1")
        )
        await client.emitDiscover(
            DiscoverEventSnapshot(sourceId: "caller", correlationId: "corr-2")
        )
        try await waitUntil("second request resolved") {
            client.publishedTopics.contains { topicEventType($0) == .resolve }
        }
        #expect(invocations == 2)
    }

    /// Existing Identity and IoNode discovery is unchanged: a discoverer that
    /// observes the Identity responder still gets the identity resolve.
    @Test
    func builtInIdentityResponderStillResolves() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        // The built-in Identity responder is installed by startClient()
        // (via observeDiscoverIdentity), so this test starts the manager
        // rather than only flipping the simulated state online.
        try manager.start()
        try await bringOnline(manager, client: client)

        // A Discover filtered by the Identity core type should produce the
        // identity Resolve publication independent of any host responder.
        await client.emitDiscover(
            DiscoverEventSnapshot(
                sourceId: "caller",
                correlationId: "corr-ident",
                coreTypes: [.Identity]
            )
        )
        try await waitUntil("identity Resolve published") {
            client.publishedTopics.contains { topicEventType($0) == .resolve }
        }
        let resolveTopic = try #require(
            client.publishedTopics.first { topicEventType($0) == .resolve }
        )
        #expect(topicCorrelationId(resolveTopic) == "corr-ident")
        let publication = try #require(
            client.publishedMessages.first {
                topicEventType($0.topic) == .resolve
            }
        )
        let event = try JSONDecoder().decode(ResolveEvent.self, from: Data(publication.message.utf8))
        #expect(event.data.object?.coreType == .Identity)
    }

    /// A fixed object shared by the focused assertions, so the resolved
    /// object identifier is deterministic.
    private static let sampleObject = CoatyObject(
        coreType: .CoatyObject,
        objectType: "com.example.Temperature",
        objectId: CoatyUUID(uuidString: "32400000-0000-4000-8000-0000000000aa")!,
        name: "Temperature"
    )
}

/// Thread-safe capture of delivered Discover requests, for the focused suite.
private actor DiscoverRequestStore {
    private var requests: [DiscoverRequest] = []

    func append(_ request: DiscoverRequest) {
        requests.append(request)
    }

    var count: Int { requests.count }

    var first: DiscoverRequest? { requests.first }
}
