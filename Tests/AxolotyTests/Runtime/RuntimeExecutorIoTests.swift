// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Testing
@testable import Axoloty

@Suite("Runtime executor typed IO")
struct RuntimeExecutorIoTests {
    @Test("stop clears typed IO work and finishes association observers")
    func stopClearsTypedIoWorkAndFinishesObservers() async throws {
        let sourceID = "00000000-0000-4000-8000-000000000731"
        let actorID = "00000000-0000-4000-8000-000000000732"
        var builder = try RuntimeBuilder(
            sourceID: try #require(UUID16(parsing: sourceID)),
            namespace: "executor-stop"
        )
        let source = try builder.ioSource(
            metadata: try runtimeIoSourceMetadata(sourceID),
            as: Bool.self,
            publication: .latest(atMostEveryMS: 1_000)
        )
        let transport = BlockingPublicationTransport(blockedCapability: .ioValue)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        let stream = try await runtime.io.associations(of: source)
        var iterator = stream.makeAsyncIterator()
        let initial = try await nextValue(&iterator)
        #expect(!initial.hasAssociations)

        let association = "{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"\(actorID)\",\"associatingRoute\":\"coaty/executor-stop\"}"
        #expect(await runtime.receive(.profile(
            route: "coaty/3/executor-stop/ASC/\(sourceID)",
            payload: Array(association.utf8),
            nowMS: 1
        )) == .accepted)
        let associated = try await nextValue(&iterator)
        #expect(associated.hasAssociations)

        #expect(try await runtime.io.publish(true, from: source, nowMS: 10) == .published)
        try await waitUntil("typed IO publication to enter the transport") {
            await transport.blockedPublicationStarted
        }
        #expect(try await runtime.io.publish(false, from: source, nowMS: 11) == .queuedLatest)

        let stopping = Task { await runtime.stop() }
        try await waitUntil("runtime stop to clear typed IO state") {
            await runtime.state() == .stopping
        }
        await transport.releaseBlockedPublication()
        await stopping.value

        #expect(await runtime.state() == .stopped)
        #expect(await transport.publicationCount(for: .ioValue) == 1)
        do {
            _ = try await nextValue(&iterator, timeout: .seconds(1))
            Issue.record("typed IO association stream remained open after stop")
        } catch is CancellationError {
            // AsyncStream reports a finished stream through the support helper.
        }
    }

    @Test("IO actor and ordinary handlers share the executor admission bound")
    func ioActorAndOrdinaryHandlerShareAdmissionCapacity() async throws {
        let sourceID = "00000000-0000-0000-0000-000000000741"
        let actorID = "00000000-0000-0000-0000-000000000742"
        let ioGate = InvocationGate()
        let channelGate = InvocationGate()
        var builder = try RuntimeBuilder(
            sourceID: try #require(UUID16(parsing: sourceID)),
            namespace: "handler-capacity",
            capacities: try RuntimeCapacities(handlersInFlight: 1)
        )
        let source = try builder.ioSource(
            metadata: try runtimeIoSourceMetadata(sourceID), as: Bool.self
        )
        _ = try builder.ioActor(
            metadata: try runtimeIoActorMetadata(actorID), as: Bool.self
        ) { _, _ in
            await ioGate.block()
        }
        _ = try builder.respond(to: .channel) { _ in
            await channelGate.block()
            return .noResponse
        }
        let runtime = AxolotyRuntime(
            definition: try builder.finish(), transport: RecordingPublicationTransport()
        )
        try await runtime.start()
        let diagnostics = await runtime.diagnostics()
        var diagnosticIterator = diagnostics.makeAsyncIterator()

        let association = "{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"\(actorID)\",\"associatingRoute\":\"coaty/handler-capacity\"}"
        #expect(await runtime.receive(.profile(
            route: "coaty/3/handler-capacity/ASC/\(sourceID)",
            payload: Array(association.utf8),
            nowMS: 1
        )) == .accepted)
        #expect(await runtime.receive(.profile(
            route: "coaty/3/handler-capacity/IOV/\(sourceID)",
            payload: Array("true".utf8),
            nowMS: 2
        )) == .accepted)
        try await waitUntil("IO actor handler to start") {
            await ioGate.startedCount > 0
        }

        #expect(await runtime.receive(.profile(
            route: "coaty/3/handler-capacity/CHN:ordinary/\(sourceID)",
            payload: Array("{}".utf8),
            nowMS: 3
        )) == .accepted)
        #expect(await channelGate.startedCount == 0)
        #expect((await runtime.diagnosticsSnapshot()).handlerSaturation == 1)
        let ordinarySaturation = try await nextValue(&diagnosticIterator)
        #expect(ordinarySaturation.kind == .capacityExceeded)
        #expect(ordinarySaturation.detail == "handler supervision capacity is full")

        await ioGate.release()
        try await waitUntil("ordinary runtime handler to start") {
            guard await channelGate.startedCount == 0 else { return true }
            _ = await runtime.receive(.profile(
                route: "coaty/3/handler-capacity/CHN:ordinary/\(sourceID)",
                payload: Array("{}".utf8),
                nowMS: 4
            ))
            return await channelGate.startedCount > 0
        }

        #expect(await runtime.receive(.profile(
            route: "coaty/3/handler-capacity/IOV/\(sourceID)",
            payload: Array("false".utf8),
            nowMS: 5
        )) == .accepted)
        #expect(await ioGate.startedCount == 1)
        let ioSaturation = try await nextValue(&diagnosticIterator)
        #expect(ioSaturation.kind == .handlerFailed)
        #expect(ioSaturation.detail == "IO actor delivery dropped: handler capacity is full")

        await channelGate.release()
        await runtime.stop()
        _ = source
    }

    @Test("latest IO publication queues behind shared transport work and flushes once")
    func latestIoPublicationQueuesBehindTransportWork() async throws {
        let sourceID = "00000000-0000-0000-0000-000000000751"
        var builder = try RuntimeBuilder(
            sourceID: try #require(UUID16(parsing: sourceID)),
            namespace: "shared-transport",
            capacities: try RuntimeCapacities(dispatch: 1)
        )
        let source = try builder.ioSource(
            metadata: try runtimeIoSourceMetadata(sourceID),
            as: Bool.self,
            publication: .latest(atMostEveryMS: 50)
        )
        let transport = BlockingPublicationTransport(blockedCapability: .channel)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        try await waitUntil("ordinary publication to occupy transport capacity") {
            if await transport.blockedPublicationStarted { return true }
            return await runtime.publish(.channel(
                identifier: "occupy-dispatch",
                payload: Array("{}".utf8)
            )) == .accepted
        }
        let association = "{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"00000000-0000-0000-0000-000000000752\",\"associatingRoute\":\"coaty/shared-transport\"}"
        #expect(await runtime.receive(.profile(
            route: "coaty/3/shared-transport/ASC/\(sourceID)",
            payload: Array(association.utf8),
            nowMS: 1
        )) == .accepted)

        #expect(try await runtime.io.publish(true, from: source, nowMS: 2) == .queuedLatest)
        #expect(await transport.publicationCount(for: .ioValue) == 0)
        try await waitUntil("a scheduled flush attempt while capacity is full") {
            await runtime.typedIoFlushAttemptsForTesting() >= 1
        }
        try await waitUntil("a retry scheduled after the first full-capacity attempt") {
            await runtime.typedIoFlushAttemptsForTesting() >= 2
        }
        await transport.releaseBlockedPublication()
        try await waitUntil("queued latest value to flush") {
            await transport.publicationCount(for: .ioValue) == 1
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.publicationCount(for: .ioValue) == 1)
        #expect(await transport.ioPayloads == [Array("true".utf8)])
        await runtime.stop()
    }
}

private actor InvocationGate {
    private(set) var startedCount = 0
    private(set) var finishedCount = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func block() async {
        startedCount += 1
        guard !released else {
            finishedCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
        finishedCount += 1
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor BlockingPublicationTransport: AxolotyRuntimeTransport {
    private let blockedCapability: ProtocolCapability
    private(set) var blockedPublicationStarted = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var publications: [RuntimeOutboundMessage] = []

    init(blockedCapability: ProtocolCapability) {
        self.blockedCapability = blockedCapability
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func stop() async {}

    func perform(_ effect: RuntimeTransportEffect) async throws {
        guard case let .publish(publication) = effect else { return }
        publications.append(publication)
        guard routeEventType(publication.route) == blockedCapability.wireEventType.wireCode.description else { return }
        blockedPublicationStarted = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func releaseBlockedPublication() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func publicationCount(for capability: ProtocolCapability) -> Int {
        publications.reduce(into: 0) { count, publication in
            if routeEventType(publication.route) == capability.wireEventType.wireCode.description { count += 1 }
        }
    }

    var ioPayloads: [[UInt8]] {
        publications.compactMap { publication in
            routeEventType(publication.route) == ProtocolCapability.ioValue.wireEventType.wireCode.description
                ? publication.payload : nil
        }
    }
}

private actor RecordingPublicationTransport: AxolotyRuntimeTransport {
    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func perform(_ effect: RuntimeTransportEffect) async throws {}
    func stop() async {}
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
}

private func runtimeIoSourceMetadata(_ id: String) throws -> Object<IoSourceMetadata> {
    guard let uuid = UUID16(parsing: id) else { throw MetadataFixtureError.invalidID }
    let envelope = try ObjectEnvelope<128, 128>(
        objectID: ObjectID(uuid: uuid),
        objectType: IoSourceMetadata.schema.objectType,
        name: BoundedEncodedText<128>("source")!,
        coreType: .ioSource
    )
    return try Object<IoSourceMetadata>(
        envelope: envelope,
        fields: IoSourceMetadata(valueType: try IoValueType("com.example.Bool"))
    )
}

private func runtimeIoActorMetadata(_ id: String) throws -> Object<IoActorMetadata> {
    guard let uuid = UUID16(parsing: id) else { throw MetadataFixtureError.invalidID }
    let envelope = try ObjectEnvelope<128, 128>(
        objectID: ObjectID(uuid: uuid),
        objectType: IoActorMetadata.schema.objectType,
        name: BoundedEncodedText<128>("actor")!,
        coreType: .ioActor
    )
    return try Object<IoActorMetadata>(
        envelope: envelope,
        fields: IoActorMetadata(valueType: try IoValueType("com.example.Bool"))
    )
}

private enum MetadataFixtureError: Error {
    case invalidID
}
