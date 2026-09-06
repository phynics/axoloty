// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

final class FakeSignalHandler: InspectorSignalHandling, @unchecked Sendable {
    var wasInterrupted = false

    func install() {}
}

final class OneShotPhase: @unchecked Sendable {
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

@MainActor
final class FakeInspectorSession: InspectorSession {
    var connectShouldFail = false
    var connectError: InspectorError?
    var connected = false
    var transportState: InspectorTransportState = .offline
    var stopped = false
    var discoverCallCount = 0
    var lastDiscoverRequest: InspectorDiscoverRequest?
    var streamsCreatedBeforeConnect = false

    private var advertiseContinuation: AsyncStream<InspectorAdvertiseEvent>.Continuation?
    private var deadvertiseContinuation: AsyncStream<InspectorDeadvertiseEvent>.Continuation?
    private var discoverContinuation: AsyncStream<InspectorResponseEvent>.Continuation?

    private var advertiseStreamCreated = false
    private var deadvertiseStreamCreated = false

    var queuedAdvertises: [InspectorAdvertiseEvent] = []
    var queuedDeadvertises: [InspectorDeadvertiseEvent] = []
    var queuedResponses: [InspectorResponseEvent] = []
    var finishDiscoverStream = true

    private let discoverStartedPhase = OneShotPhase()

    init() {}

    func connect() async throws {
        if connectShouldFail {
            throw connectError ?? .connectionUnavailable(reason: "fake failure")
        }
        connected = true
        transportState = .online
        streamsCreatedBeforeConnect = advertiseStreamCreated && deadvertiseStreamCreated
        for snapshot in queuedAdvertises {
            advertiseContinuation?.yield(snapshot)
        }
        for snapshot in queuedDeadvertises {
            deadvertiseContinuation?.yield(snapshot)
        }
    }

    func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: InspectorAdvertiseEvent.self)
        advertiseContinuation = cont
        advertiseStreamCreated = true
        return stream
    }

    func transportState() async -> InspectorTransportState {
        transportState
    }

    func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: InspectorDeadvertiseEvent.self)
        deadvertiseContinuation = cont
        deadvertiseStreamCreated = true
        return stream
    }

    func stop() {
        stopped = true
        advertiseContinuation?.finish()
        deadvertiseContinuation?.finish()
        discoverContinuation?.finish()
        discoverStartedPhase.finish()
    }

    func discover(_ event: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent> {
        discoverCallCount += 1
        lastDiscoverRequest = event
        let (stream, cont) = AsyncStream.makeStream(of: InspectorResponseEvent.self)
        discoverContinuation = cont
        discoverStartedPhase.signal()
        for response in queuedResponses {
            cont.yield(response)
        }
        if finishDiscoverStream {
            cont.finish()
        }
        return stream
    }

    func emitAdvertise(_ snapshot: InspectorAdvertiseEvent) {
        advertiseContinuation?.yield(snapshot)
    }

    func emitDeadvertise(_ snapshot: InspectorDeadvertiseEvent) {
        deadvertiseContinuation?.yield(snapshot)
    }

    func endStreams() {
        advertiseContinuation?.finish()
        deadvertiseContinuation?.finish()
    }

    func discoverStartedSignal() -> OneShotPhase {
        discoverStartedPhase
    }

    func finishPhases() {
        discoverStartedPhase.finish()
    }
}
