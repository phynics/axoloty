// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Testing

@MainActor
private final class RetryInspectorSession: InspectorSession {
    var failuresRemaining = 1
    var connectDelay: Duration = .zero
    var blockConnect = false
    private(set) var connectAttempts = 0
    private(set) var streamsCreatedBeforeConnect: [Bool] = []
    private(set) var connectStarted = false

    private var advertiseStreamCreated = false
    private var deadvertiseStreamCreated = false
    private var advertiseContinuations: [AsyncStream<AdvertiseEventSnapshot>.Continuation] = []
    private var deadvertiseContinuations: [AsyncStream<DeadvertiseEventSnapshot>.Continuation] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?

    func connect() async throws {
        connectAttempts += 1
        connectStarted = true
        streamsCreatedBeforeConnect.append(advertiseStreamCreated && deadvertiseStreamCreated)
        advertiseStreamCreated = false
        deadvertiseStreamCreated = false

        if blockConnect {
            await withCheckedContinuation { continuation in
                connectWaiter = continuation
            }
        }
        if connectDelay > .zero {
            try await Task.sleep(for: connectDelay)
        }

        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw InspectorError.connectionUnavailable(reason: "fake failure")
        }
    }

    func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot> {
        advertiseStreamCreated = true
        let (stream, continuation) = AsyncStream.makeStream(of: AdvertiseEventSnapshot.self)
        advertiseContinuations.append(continuation)
        return stream
    }

    func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot> {
        deadvertiseStreamCreated = true
        let (stream, continuation) = AsyncStream.makeStream(of: DeadvertiseEventSnapshot.self)
        deadvertiseContinuations.append(continuation)
        return stream
    }

    func discover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func stop() {}

    func emitAdvertise(_ snapshot: AdvertiseEventSnapshot) {
        advertiseContinuations.last?.yield(snapshot)
    }

    func emitAdvertise(_ snapshot: AdvertiseEventSnapshot, onStream index: Int) {
        advertiseContinuations[index].yield(snapshot)
    }

    func emitDeadvertise(_ snapshot: DeadvertiseEventSnapshot) {
        deadvertiseContinuations.last?.yield(snapshot)
    }

    func releaseConnect() {
        connectWaiter?.resume()
        connectWaiter = nil
    }
}

@Test
@MainActor
func catalogueServiceCanRetryAfterFailedConnection() async {
    let session = RetryInspectorSession()
    let service = InspectorCatalogueService(session: session, namespace: "test")

    await #expect(throws: InspectorError.self) {
        try await service.start()
    }
    do {
        try await service.start()
    } catch {
        Issue.record("Expected retry to connect successfully, got \(error)")
    }

    #expect(session.connectAttempts == 2)
    #expect(session.streamsCreatedBeforeConnect == [true, true])

    session.emitAdvertise(
        AdvertiseEventSnapshot(
            sourceId: "source-1",
            eventTypeFilter: CoreType.Identity.rawValue,
            object: CoatyObjectSnapshot(
                objectId: "object-1",
                coreType: .Identity,
                objectType: "coaty.object.Identity",
                name: "Agent"
            )
        )
    )
    for _ in 0..<100 {
        if await service.store.count > 0 {
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.store.count == 1)

    session.emitDeadvertise(DeadvertiseEventSnapshot(objectIds: ["object-1"]))
    for _ in 0..<100 {
        if await service.store.count == 0 {
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.store.count == 0)
}

@Test
@MainActor
func concurrentCatalogueServiceStartsShareOneConnection() async {
    let session = RetryInspectorSession()
    session.failuresRemaining = 0
    session.connectDelay = .milliseconds(50)
    let service = InspectorCatalogueService(session: session, namespace: "test")

    let firstStart = Task { @MainActor in
        try await service.start()
    }
    try? await Task.sleep(for: .milliseconds(10))
    let secondStart = Task { @MainActor in
        try await service.start()
    }

    do {
        try await firstStart.value
        try await secondStart.value
    } catch {
        Issue.record("Expected concurrent starts to succeed, got \(error)")
    }

    #expect(session.connectAttempts == 1)
    #expect(session.streamsCreatedBeforeConnect == [true])
}

@Test
@MainActor
func stoppingDuringCatalogueServiceStartPreventsLateConsumer() async {
    let session = RetryInspectorSession()
    session.failuresRemaining = 0
    session.blockConnect = true
    let service = InspectorCatalogueService(session: session, namespace: "test")

    let inFlightStart = Task { @MainActor in
        try await service.start()
    }
    while !session.connectStarted {
        try? await Task.sleep(for: .milliseconds(1))
    }

    service.stop()
    session.releaseConnect()
    session.blockConnect = false
    let retryStart = Task { @MainActor in
        try await service.start()
    }
    await #expect(throws: CancellationError.self) {
        try await inFlightStart.value
    }
    do {
        try await retryStart.value
    } catch {
        Issue.record("Expected retry after stop to connect successfully, got \(error)")
    }
    let object = AdvertiseEventSnapshot(
        sourceId: "source-1",
        eventTypeFilter: CoreType.Identity.rawValue,
        object: CoatyObjectSnapshot(
            objectId: "object-1",
            coreType: .Identity,
            objectType: "coaty.object.Identity",
            name: "Agent"
        )
    )
    session.emitAdvertise(object, onStream: 0)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await service.store.count == 0)

    session.emitAdvertise(object, onStream: 1)
    for _ in 0..<100 {
        if await service.store.count > 0 {
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.store.count == 1)
}
