// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
@testable import AxolotyZenoh
@testable import AxolotyZenohCore

@Suite("Zenoh receive pump")
struct ZenohBindingReceivePumpTests {
    @Test("copies and classifies queued profile and external frames at receive time")
    func copiesAndClassifiesFrames() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session, clock: { 1234 })
        let counters = RuntimeTransportDiagnostics()
        await binding.setDiagnostics(counters)
        let recorder = FrameRecorder()
        try await binding.start { recorder.append($0) }
        try await binding.activateProfileInterest(namespace: "node")
        let externalRoute = "legacy/source/value"
        try await binding.perform(.externalRouteActivated(transition(externalRoute)))
        let profileRoute = "coaty/3/node/IOV/00000000-0000-4000-8000-000000000001"
        session.enqueue(.frame(PollFrameSource(key: Array(profileRoute.utf8), payload: [0, 1, 255])), for: 1)
        session.enqueue(.frame(PollFrameSource(key: Array(externalRoute.utf8), payload: [3, 4])), for: 3)

        binding.drainReceiveQueues()

        let frames = recorder.snapshot()
        #expect(frames.count == 2)
        #expect(frames.first == .profile(route: profileRoute, payload: [0, 1, 255], nowMS: 1234))
        #expect(frames.last == .externalIo(route: externalRoute, payload: [3, 4], nowMS: 1234))
        #expect(counters.snapshot().receivedFrames == 2)
        await binding.stop()
    }

    @Test("consumes queue drop notifications without delivering frames")
    func consumesDropNotifications() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        let counters = RuntimeTransportDiagnostics()
        await binding.setDiagnostics(counters)
        let recorder = FrameRecorder()
        try await binding.start { recorder.append($0) }
        try await binding.activateProfileInterest(namespace: "node")
        session.enqueue(.result(.queueFull), for: 1)
        session.enqueue(.result(.frameTooLarge), for: 1)

        binding.drainReceiveQueues()

        #expect(recorder.snapshot().isEmpty)
        #expect(session.pollCount >= 3)
        #expect(counters.snapshot().receiveDrops == 1)
        #expect(counters.snapshot().oversizedSamples == 1)
        #expect(counters.snapshot().sessionOpens == 1)
        await binding.stop()
    }

    @Test("forwards transport and closed-session poll failures")
    func forwardsPollFailures() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        let failures = FailureRecorder()
        await binding.setFailureHandler { failures.append($0) }
        try await binding.start { _ in }
        try await binding.activateProfileInterest(namespace: "node")
        session.enqueue(.result(.transportError), for: 1)

        #expect(!binding.drainReceiveQueues())
        session.enqueue(.result(.notOpen), for: 1)
        #expect(!binding.drainReceiveQueues())

        #expect(failures.snapshot() == [
            RuntimeTransportFailure(code: .brokerUnavailable, detail: "Zenoh receive poll failed in the Zenoh transport"),
            RuntimeTransportFailure(code: .notStarted, detail: "Zenoh receive poll requires an open Zenoh session"),
        ])
        await binding.stop()
    }

    @Test("owns copied buffers and joins the pump on stop")
    func ownsBuffersAndStops() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        let recorder = FrameRecorder()
        try await binding.start { recorder.append($0) }
        try await binding.perform(.externalRouteActivated(transition("legacy/value")))
        session.mutateQueuedBytesAfterPoll = true
        session.enqueue(.frame(PollFrameSource(key: Array("legacy/value".utf8), payload: [8, 9])), for: 1)

        binding.drainReceiveQueues()
        await binding.stop()
        let countAfterStop = session.pollCount
        binding.drainReceiveQueues()

        #expect(recorder.snapshot() == [.externalIo(route: "legacy/value", payload: [8, 9], nowMS: 0)])
        #expect(session.pollCount == countAfterStop)
        #expect(session.operations.last == .close)
    }

    private func makeBinding(
        session: any ZenohBindingSession,
        clock: @escaping @Sendable () -> UInt32 = { 0 }
    ) throws -> ZenohBinding {
        let configuration = try ZenohBindingConfiguration()
        return ZenohBinding(
            configuration: configuration,
            session: session,
            clock: clock,
            receivePumpIntervalNanoseconds: 60_000_000_000
        )
    }

    private func transition(_ route: String) -> OwnedExternalRouteTransition {
        OwnedExternalRouteTransition(sourceID: .zero, actorID: .zero, route: Array(route.utf8))
    }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RuntimeInboundFrame] = []

    func append(_ frame: RuntimeInboundFrame) {
        lock.withLock { frames.append(frame) }
    }

    func snapshot() -> [RuntimeInboundFrame] {
        lock.withLock { frames }
    }
}
