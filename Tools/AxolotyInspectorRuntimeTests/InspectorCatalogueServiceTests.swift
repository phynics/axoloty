// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Testing

private final class OneShotPhase: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func signal() {
        continuation.yield(())
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

private func waitForPhase(
    _ phase: OneShotPhase,
    description: String,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in phase.stream {
                return true
            }
            return false
        }
        group.addTask {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return false
            }
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        if !result {
            Issue.record("Timed out waiting for inspector phase: \(description)")
        }
        return result
    }
}

private func waitForStableStoreCount(
    _ store: InspectorCatalogueStore,
    expected: Int,
    description: String,
    timeout: Duration = .seconds(2),
    stabilityWindow: Duration = .milliseconds(25)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var actual = await store.count

    while clock.now < deadline {
        actual = await store.count
        if actual == expected {
            let stableUntil = clock.now.advanced(by: stabilityWindow)
            while clock.now < stableUntil {
                actual = await store.count
                if actual != expected {
                    Issue.record(
                        "Inspector phase \(description) changed catalogue count: "
                            + "expected \(expected), got \(actual)"
                    )
                    return false
                }
                await Task.yield()
            }
            return true
        }
        await Task.yield()
    }

    Issue.record(
        "Timed out waiting for inspector phase \(description): "
            + "expected catalogue count \(expected), got \(actual)"
    )
    return false
}

@MainActor
private final class RetryInspectorSession: InspectorSession {
    var failuresRemaining = 1
    var connectDelay: Duration = .zero
    var blockConnect = false
    private(set) var connectAttempts = 0
    private(set) var streamsCreatedBeforeConnect: [Bool] = []
    private(set) var connectStarted = false
    var currentInspectorTransportState: InspectorTransportState = .offline

    private var advertiseStreamCreated = false
    private var deadvertiseStreamCreated = false
    private var advertiseContinuations: [AsyncStream<InspectorAdvertiseEvent>.Continuation] = []
    private var deadvertiseContinuations: [AsyncStream<InspectorDeadvertiseEvent>.Continuation] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private let connectStartedPhase = OneShotPhase()
    private var advertisePhases: [OneShotPhase] = []
    private var deadvertisePhases: [OneShotPhase] = []

    func connect() async throws {
        connectAttempts += 1
        connectStarted = true
        connectStartedPhase.signal()
        streamsCreatedBeforeConnect.append(advertiseStreamCreated && deadvertiseStreamCreated)
        advertiseStreamCreated = false
        deadvertiseStreamCreated = false

        if blockConnect {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    connectWaiter = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.releaseConnect()
                }
            }
        }
        if connectDelay > .zero {
            try await Task.sleep(for: connectDelay)
        }

        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw InspectorError.connectionUnavailable(reason: "fake failure")
        }
        currentInspectorTransportState = .online
    }

    func transportState() async -> InspectorTransportState {
        currentInspectorTransportState
    }

    func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent> {
        advertiseStreamCreated = true
        let (stream, continuation) = AsyncStream.makeStream(of: InspectorAdvertiseEvent.self)
        advertiseContinuations.append(continuation)
        advertisePhases.append(OneShotPhase())
        return stream
    }

    func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent> {
        deadvertiseStreamCreated = true
        let (stream, continuation) = AsyncStream.makeStream(of: InspectorDeadvertiseEvent.self)
        deadvertiseContinuations.append(continuation)
        deadvertisePhases.append(OneShotPhase())
        return stream
    }

    func discover(_ event: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func stop() {
        releaseConnect()
        for continuation in advertiseContinuations { continuation.finish() }
        for continuation in deadvertiseContinuations { continuation.finish() }
        finishPhases()
    }

    func emitAdvertise(_ snapshot: InspectorAdvertiseEvent) {
        guard let index = advertiseContinuations.indices.last else { return }
        emitAdvertise(snapshot, onStream: index)
    }

    func emitAdvertise(_ snapshot: InspectorAdvertiseEvent, onStream index: Int) {
        advertiseContinuations[index].yield(snapshot)
        advertisePhases[index].signal()
    }

    func emitDeadvertise(_ snapshot: InspectorDeadvertiseEvent) {
        guard let index = deadvertiseContinuations.indices.last else { return }
        deadvertiseContinuations[index].yield(snapshot)
        deadvertisePhases[index].signal()
    }

    func releaseConnect() {
        connectWaiter?.resume()
        connectWaiter = nil
    }

    func connectStartedSignal() -> OneShotPhase { connectStartedPhase }

    func advertiseSignal(onStream index: Int) -> OneShotPhase {
        advertisePhases[index]
    }

    func deadvertiseSignal(onStream index: Int = 0) -> OneShotPhase {
        deadvertisePhases[index]
    }

    func finishPhases() {
        connectStartedPhase.finish()
        for phase in advertisePhases { phase.finish() }
        for phase in deadvertisePhases { phase.finish() }
    }
}

@Test
@MainActor
func catalogueServiceCanRetryAfterFailedConnection() async {
    let session = RetryInspectorSession()
    let service = InspectorCatalogueService(session: session, namespace: "test")
    defer {
        service.stop()
        session.finishPhases()
    }

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
        InspectorAdvertiseEvent(
            sourceId: "source-1",
            eventTypeFilter: InspectorCoreType.Identity.rawValue,
            object: InspectorObjectPayload(
                objectId: "object-1",
                coreType: .Identity,
                objectType: "coaty.object.Identity",
                name: "Agent"
            )
        )
    )
    #expect(await waitForPhase(
        session.advertiseSignal(onStream: 1),
        description: "advertise event enqueued on active stream"
    ))
    #expect(await waitForStableStoreCount(
        service.store,
        expected: 1,
        description: "active advertise processing"
    ))

    session.emitDeadvertise(InspectorDeadvertiseEvent(objectIds: ["object-1"]))
    #expect(await waitForPhase(
        session.deadvertiseSignal(),
        description: "deadvertise event enqueued on active stream"
    ))
    #expect(await waitForStableStoreCount(
        service.store,
        expected: 0,
        description: "active deadvertise processing"
    ))
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
    #expect(await waitForPhase(
        session.connectStartedSignal(),
        description: "first concurrent connection start"
    ))
    let secondStart = Task { @MainActor in
        try await service.start()
    }
    defer {
        firstStart.cancel()
        secondStart.cancel()
        service.stop()
        session.finishPhases()
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
    var retryStart: Task<Void, Error>?
    defer {
        inFlightStart.cancel()
        retryStart?.cancel()
        session.releaseConnect()
        service.stop()
        session.finishPhases()
    }
    #expect(await waitForPhase(
        session.connectStartedSignal(),
        description: "blocked connection start"
    ))

    service.stop()
    session.releaseConnect()
    session.blockConnect = false
    retryStart = Task { @MainActor in
        try await service.start()
    }
    await #expect(throws: CancellationError.self) {
        try await inFlightStart.value
    }
    do {
        try await retryStart!.value
    } catch {
        Issue.record("Expected retry after stop to connect successfully, got \(error)")
    }
    let staleObject = InspectorAdvertiseEvent(
        sourceId: "source-1",
        eventTypeFilter: InspectorCoreType.Identity.rawValue,
        object: InspectorObjectPayload(
            objectId: "stale-object",
            coreType: .Identity,
            objectType: "coaty.object.Identity",
            name: "Agent"
        )
    )
    let activeObject = InspectorAdvertiseEvent(
        sourceId: "source-1",
        eventTypeFilter: InspectorCoreType.Identity.rawValue,
        object: InspectorObjectPayload(
            objectId: "active-object",
            coreType: .Identity,
            objectType: "coaty.object.Identity",
            name: "Agent"
        )
    )
    session.emitAdvertise(staleObject, onStream: 0)
    #expect(await waitForPhase(
        session.advertiseSignal(onStream: 0),
        description: "stale advertise event enqueued after stop"
    ))
    #expect(await waitForStableStoreCount(
        service.store,
        expected: 0,
        description: "stale advertise suppression"
    ))

    session.emitAdvertise(activeObject, onStream: 1)
    #expect(await waitForPhase(
        session.advertiseSignal(onStream: 1),
        description: "retry advertise event enqueued on active stream"
    ))
    #expect(await waitForStableStoreCount(
        service.store,
        expected: 1,
        description: "retry advertise processing"
    ))
    #expect(await service.store.object(id: "active-object") != nil)
    #expect(await service.store.object(id: "stale-object") == nil)
}
