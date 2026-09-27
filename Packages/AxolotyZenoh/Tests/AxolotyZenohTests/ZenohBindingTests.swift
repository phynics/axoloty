// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Foundation

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire
@testable import AxolotyZenoh
@testable import AxolotyZenohCore

@Suite("Zenoh runtime transport")
struct ZenohBindingTests {
    @Test("starts and stops one serialized session")
    func startAndStop() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)

        try await binding.start(
            receive: { _ in },
            lastWill: RuntimeTransportLastWill(topic: "will", payload: [1])
        )
        await binding.stop()

        #expect(session.operations == [.open(Array("tcp/127.0.0.1:7447".utf8)), .close])
    }

    @Test("publishes the resolved route and an owned payload copy")
    func publishMapping() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }
        var payload: [UInt8] = [0, 1, 2, 255]
        let message = RuntimeOutboundMessage(route: "coaty/3/node/ADV/source", payload: payload)
        payload[0] = 99

        try await binding.perform(.publish(message))

        #expect(session.operations.last == .publish(
            Array("coaty/3/node/ADV/source".utf8),
            [0, 1, 2, 255]
        ))
        await binding.stop()
    }

    @Test("activates and deactivates one exact external route")
    func exactExternalRouteLifecycle() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }
        let route = "legacy/source/value"

        try await binding.perform(.externalRouteActivated(transition(route)))
        try await binding.perform(.externalRouteActivated(transition(route)))
        try await binding.perform(.externalRouteDeactivated(transition(route)))
        try await binding.perform(.externalRouteDeactivated(transition(route)))
        await #expect(throws: AxolotyError.self) {
            try await binding.perform(.externalRouteActivated(transition("legacy/*/value")))
        }

        #expect(session.operations == [
            .open(Array("tcp/127.0.0.1:7447".utf8)),
            .subscribe(Array(route.utf8), id: 1),
            .unsubscribe(1),
        ])
        await binding.stop()
    }

    @Test("installs and removes exactly the two bounded profile shapes")
    func profileInterestMapping() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }

        try await binding.activateProfileInterest(namespace: "node")
        try await binding.deactivateProfileInterest(namespace: "node")
        let operationCount = session.operations.count
        for invalidNamespace in ["", "a/b", "a#b", "a+b", "a*b", String(repeating: "a", count: 65)] {
            await #expect(throws: AxolotyError.self) {
                try await binding.activateProfileInterest(namespace: invalidNamespace)
            }
        }
        #expect(session.operations.count == operationCount)

        #expect(session.operations == [
            .open(Array("tcp/127.0.0.1:7447".utf8)),
            .subscribe(Array("coaty/3/node/*/*".utf8), id: 1),
            .subscribe(Array("coaty/3/node/*/*/*".utf8), id: 2),
            .unsubscribe(1),
            .unsubscribe(2),
        ])
        let subscribedRoutes = session.operations.compactMap { operation -> [UInt8]? in
            guard case let .subscribe(route, _) = operation else { return nil }
            return route
        }
        #expect(!subscribedRoutes.contains(Array("coaty/3/node/**".utf8)))
        await binding.stop()
    }

    @Test("retains profile handles when rollback removal fails")
    func profileSubscriptionRollbackRetainsHandles() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }
        session.subscribeFailureOnAttempt = 2
        session.unsubscribeResult = .transportError

        do {
            try await binding.activateProfileInterest(namespace: "node")
            Issue.record("expected profile subscription failure")
        } catch {
            #expect(error.userFriendlyMessage.contains("injected subscribe failure"))
            #expect(error.userFriendlyMessage.contains("rollback failed"))
        }
        session.unsubscribeResult = .success
        try await binding.deactivateProfileInterest(namespace: "node")

        #expect(session.operations == [
            .open(Array("tcp/127.0.0.1:7447".utf8)),
            .subscribe(Array("coaty/3/node/*/*".utf8), id: 1),
            .subscribe(Array("coaty/3/node/*/*/*".utf8), id: 2),
            .unsubscribe(1),
            .unsubscribe(1),
        ])
        await binding.stop()
    }

    @Test("same-namespace profile interest recovers after retained rollback handles are cleared")
    func profileInterestReactivationAfterRollback() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }
        session.subscribeFailureOnAttempt = 2
        session.unsubscribeResult = .transportError
        await #expect(throws: AxolotyError.self) {
            try await binding.activateProfileInterest(namespace: "node")
        }

        session.unsubscribeResult = .success
        do {
            try await binding.activateProfileInterest(namespace: "node")
            Issue.record("incomplete retained state must require explicit cleanup")
        } catch {
            guard case let .runtime(code, _) = error else {
                Issue.record("expected incomplete-state error, got \(error)")
                return
            }
            #expect(code == .subscriptionFailed)
        }
        try await binding.deactivateProfileInterest(namespace: "node")
        session.subscribeFailureOnAttempt = nil
        try await binding.activateProfileInterest(namespace: "node")
        try await binding.deactivateProfileInterest(namespace: "node")

        #expect(session.operations.suffix(4).elementsEqual([
            .subscribe(Array("coaty/3/node/*/*".utf8), id: 3),
            .subscribe(Array("coaty/3/node/*/*/*".utf8), id: 4),
            .unsubscribe(3),
            .unsubscribe(4),
        ]))
        await binding.stop()
        #expect(session.operations.last == .close)
    }

    @Test("profile namespace changes are rejected and stopped deactivation is harmless")
    func profileNamespaceAndStoppedDeactivationContract() async throws {
        let binding = try makeBinding(session: RecordingZenohSession())
        try await binding.deactivateProfileInterest(namespace: "node")
        try await binding.start { _ in }
        try await binding.activateProfileInterest(namespace: "node")

        do {
            try await binding.activateProfileInterest(namespace: "other")
            Issue.record("a live profile namespace cannot be replaced in place")
        } catch {
            guard case .invalidConfiguration = error else {
                Issue.record("expected invalidConfiguration, got \(error)")
                return
            }
        }

        await binding.stop()
        try await binding.deactivateProfileInterest(namespace: "node")
    }

    @Test("classifies routes using the active namespace and binding bounds")
    func routeClassification() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }

        #expect(classify("other/source", with: binding) == .external)
        let profileRoute = "coaty/3/node/IOV/00000000-0000-4000-8000-000000000001"
        #expect(classify(profileRoute, with: binding) == .unrelated)
        try await binding.activateProfileInterest(namespace: "node")
        #expect(classify(profileRoute, with: binding) == .coaty)
        #expect(classify("coaty/3/other/IOV/00000000-0000-4000-8000-000000000001", with: binding) == .unrelated)
        #expect(classify("coaty/3/node/ADV/00000000-0000-4000-8000-000000000001", with: binding) == .unrelated)
        #expect(classify("bad//route", with: binding) == .unrelated)
        #expect(classify("bad/+/route", with: binding) == .unrelated)
        #expect(classify("bad/*/route", with: binding) == .unrelated)

        await binding.stop()
        #expect(classify(profileRoute, with: binding) == .unrelated)
    }

    @Test("ignores close failures during an intentional stop")
    func stopDoesNotReportCloseFailure() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        let recorder = FailureRecorder()
        await binding.setFailureHandler { recorder.append($0) }
        try await binding.start { _ in }
        session.closeResult = .transportError

        await binding.stop()

        #expect(recorder.snapshot().isEmpty)
    }

    @Test("forwards owned asynchronous transport failures")
    func failureForwarding() async throws {
        let binding = try makeBinding(session: RecordingZenohSession())
        let recorder = FailureRecorder()
        await binding.setFailureHandler { recorder.append($0) }
        try await binding.start { _ in }
        let failure = RuntimeTransportFailure(code: .brokerUnavailable, detail: "session lost")

        binding.reportFailure(failure)

        #expect(recorder.snapshot() == [failure])
        await binding.stop()
    }

    @Test("debounces router loss and emits one failure and one recovery per outage")
    func routerLossDebounceAndRecovery() async throws {
        let session = RecordingZenohSession()
        let now = NanosecondTestClock()
        let binding = try makeBinding(session: session, now: { now.value }, debounce: 1_000)
        let failures = FailureRecorder()
        let recoveries = RecoveryRecorder()
        await binding.setFailureHandler { failures.append($0) }
        await binding.setRecoveryHandler { recoveries.append() }
        try await binding.start { _ in }

        binding.drainReceiveQueues()
        now.advance(by: 10_000)
        binding.drainReceiveQueues()
        #expect(failures.snapshot().isEmpty)

        session.connectedRouters = 1
        binding.drainReceiveQueues()
        session.connectedRouters = 0
        binding.drainReceiveQueues()
        now.advance(by: 999)
        binding.drainReceiveQueues()
        #expect(failures.snapshot().isEmpty)

        now.advance(by: 1)
        binding.drainReceiveQueues()
        binding.drainReceiveQueues()
        #expect(failures.snapshot() == [RuntimeTransportFailure(
            code: .brokerUnavailable,
            detail: ZenohBinding.routerLossFailureDetail
        )])

        session.connectedRouters = 1
        binding.drainReceiveQueues()
        binding.drainReceiveQueues()
        #expect(recoveries.snapshot() == 1)
        #expect(failures.snapshot().count == 1)
        await binding.stop()
    }

    @Test("router presence query failures use the same debounced loss path")
    func routerPresenceQueryFailureIsDebounced() async throws {
        let session = RecordingZenohSession()
        let now = NanosecondTestClock()
        let binding = try makeBinding(session: session, now: { now.value }, debounce: 1_000)
        let failures = FailureRecorder()
        await binding.setFailureHandler { failures.append($0) }
        try await binding.start { _ in }
        session.connectedRouters = 1
        binding.drainReceiveQueues()

        session.connectedRouterQueryFailure = .transportError
        binding.drainReceiveQueues()
        now.advance(by: 999)
        binding.drainReceiveQueues()
        #expect(failures.snapshot().isEmpty)

        now.advance(by: 1)
        binding.drainReceiveQueues()
        #expect(failures.snapshot() == [RuntimeTransportFailure(
            code: .brokerUnavailable,
            detail: ZenohBinding.routerLossFailureDetail
        )])
        await binding.stop()
    }

    @Test("a router return inside the debounce window resets the loss timer")
    func routerPresenceFlapResetsDebounce() async throws {
        let session = RecordingZenohSession()
        let now = NanosecondTestClock()
        let binding = try makeBinding(session: session, now: { now.value }, debounce: 1_000)
        let failures = FailureRecorder()
        await binding.setFailureHandler { failures.append($0) }
        try await binding.start { _ in }
        session.connectedRouters = 1
        binding.drainReceiveQueues()

        session.connectedRouters = 0
        binding.drainReceiveQueues()
        now.advance(by: 999)
        binding.drainReceiveQueues()
        session.connectedRouters = 1
        binding.drainReceiveQueues()
        session.connectedRouters = 0
        binding.drainReceiveQueues()
        now.advance(by: 999)
        binding.drainReceiveQueues()
        #expect(failures.snapshot().isEmpty)

        now.advance(by: 1)
        binding.drainReceiveQueues()
        #expect(failures.snapshot().count == 1)
        await binding.stop()
    }

    @Test("an intentional stop during router absence does not report failure")
    func intentionalStopDuringRouterLossIsSilent() async throws {
        let session = RecordingZenohSession()
        let now = NanosecondTestClock()
        let binding = try makeBinding(session: session, now: { now.value }, debounce: 1_000)
        let failures = FailureRecorder()
        await binding.setFailureHandler { failures.append($0) }
        try await binding.start { _ in }
        session.connectedRouters = 1
        binding.drainReceiveQueues()
        session.connectedRouters = 0
        binding.drainReceiveQueues()
        now.advance(by: 1_000)

        await binding.stop()
        #expect(!binding.drainReceiveQueues())
        #expect(failures.snapshot().isEmpty)
    }

    @Test("maps façade capacity errors through the transport boundary")
    func capacityErrorMapping() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }
        session.publishResult = .capacityExceeded

        do {
            try await binding.perform(.publish(RuntimeOutboundMessage(route: "key", payload: [])))
            Issue.record("expected Zenoh capacity failure")
        } catch {
            guard case let .runtime(code, _) = error else {
                Issue.record("expected runtime capacity error, got \(error)")
                return
            }
            #expect(code == .capacityExceeded)
        }

        await binding.stop()
    }

    @Test("maps invalid-argument, closed-session, and transport failures")
    func otherFacadeErrorMappings() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        try await binding.start { _ in }

        for (result, expectedCode) in [
            (ZenohResult.notOpen, AxolotyError.RuntimeErrorCode.notStarted),
            (.transportError, .brokerUnavailable),
        ] {
            session.publishResult = result
            do {
                try await binding.perform(.publish(RuntimeOutboundMessage(route: "key", payload: [])))
                Issue.record("expected mapped failure for \(result)")
            } catch {
                guard case let .runtime(code, _) = error else {
                    Issue.record("expected runtime error for \(result), got \(error)")
                    continue
                }
                #expect(code == expectedCode)
            }
        }

        session.publishResult = .invalidArgument
        do {
            try await binding.perform(.publish(RuntimeOutboundMessage(route: "key", payload: [])))
            Issue.record("expected invalid-argument failure")
        } catch {
            guard case .invalidArgument = error else {
                Issue.record("expected invalid-argument error, got \(error)")
                return
            }
        }

        await binding.stop()
    }

    @Test("rejects transport effects before start with a runtime error")
    func rejectsEffectsBeforeStart() async throws {
        let binding = try makeBinding(session: RecordingZenohSession())

        await #expect(throws: AxolotyError.self) {
            try await binding.perform(.publish(RuntimeOutboundMessage(route: "key", payload: [])))
        }
    }

    @Test("maps typed binding configuration failures to AxolotyError")
    func mapsConfigurationFailures() {
        #expect(throws: AxolotyError.self) {
            _ = try ZenohBinding(connectEndpoint: "invalid endpoint")
        }
    }

    private func makeBinding(
        session: any ZenohBindingSession,
        clock: @escaping @Sendable () -> UInt32 = { 0 },
        receivePumpIntervalNanoseconds: UInt64 = 60_000_000_000,
        now: @escaping @Sendable () -> UInt64 = { 0 },
        debounce: UInt64 = ZenohBinding.routerLossDebounceNanoseconds
    ) throws -> ZenohBinding {
        let configuration = try ZenohBindingConfiguration()
        return ZenohBinding(
            configuration: configuration,
            session: session,
            clock: clock,
            receivePumpIntervalNanoseconds: receivePumpIntervalNanoseconds,
            monotonicNowNanoseconds: now,
            routerLossDebounceNanoseconds: debounce
        )
    }

    private func transition(_ route: String) -> OwnedExternalRouteTransition {
        OwnedExternalRouteTransition(sourceID: .zero, actorID: .zero, route: Array(route.utf8))
    }

    private func classify(_ route: String, with binding: ZenohBinding) -> ProtocolRouteClassification {
        let bytes = Array(route.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            binding.classifyRoute(ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }
}

final class RecordingZenohSession: ZenohBindingSession {
    enum Operation: Equatable {
        case open([UInt8])
        case close
        case publish([UInt8], [UInt8])
        case subscribe([UInt8], id: Int)
        case unsubscribe(Int)
    }

    private(set) var operations: [Operation] = []
    private var nextID = 0
    private var queuedPolls: [Int: [PollEntry]] = [:]
    private(set) var pollCount = 0
    var mutateQueuedBytesAfterPoll = false
    var closeResult: ZenohResult = .success
    var publishResult: ZenohResult = .success
    var unsubscribeResult: ZenohResult = .success
    var subscribeFailureOnAttempt: Int?
    var connectedRouters: UInt32 = 0
    var connectedRouterQueryFailure: ZenohResult?

    enum PollEntry {
        case frame(PollFrameSource)
        case result(ZenohResult)
    }

    func open(endpoint: [UInt8]) -> ZenohResult {
        operations.append(.open(endpoint))
        return .success
    }

    func close() -> ZenohResult {
        operations.append(.close)
        return closeResult
    }

    func publish(route: [UInt8], payload: [UInt8]) -> ZenohResult {
        operations.append(.publish(route, payload))
        return publishResult
    }

    func subscribe(route: [UInt8]) throws(AxolotyError) -> Int {
        nextID += 1
        operations.append(.subscribe(route, id: nextID))
        if nextID == subscribeFailureOnAttempt {
            throw AxolotyError.runtime(code: .subscriptionFailed, reason: "injected subscribe failure")
        }
        return nextID
    }

    func unsubscribe(_ subscription: Int) -> ZenohResult {
        operations.append(.unsubscribe(subscription))
        return unsubscribeResult
    }

    func enqueue(_ entry: PollEntry, for subscription: Int) {
        queuedPolls[subscription, default: []].append(entry)
    }

    func poll(_ subscription: Int, into storage: inout ZenohFrameStorage) -> ZenohPollResult {
        pollCount += 1
        guard var entries = queuedPolls[subscription], !entries.isEmpty else { return .result(.queueEmpty) }
        let entry = entries.removeFirst()
        queuedPolls[subscription] = entries
        switch entry {
        case let .frame(source):
            let key = source.key
            let payload = source.payload
            storage.withMutableBuffers { keyBuffer, payloadBuffer in
                for (index, byte) in key.enumerated() { keyBuffer[index] = byte }
                for (index, byte) in payload.enumerated() { payloadBuffer[index] = byte }
            }
            storage.setLengths(key: key.count, payload: payload.count)
            if mutateQueuedBytesAfterPoll {
                source.key = Array(repeating: 0, count: key.count)
                source.payload = Array(repeating: 0, count: payload.count)
            }
            return .frame(ZenohFrame(keyLength: key.count, payloadLength: payload.count))
        case let .result(result):
            return .result(result)
        }
    }

    func connectedRouterCount() -> ZenohRouterCountResult {
        if let connectedRouterQueryFailure { return .failure(connectedRouterQueryFailure) }
        return .count(connectedRouters)
    }
}

final class PollFrameSource {
    var key: [UInt8]
    var payload: [UInt8]

    init(key: [UInt8], payload: [UInt8]) {
        self.key = key
        self.payload = payload
    }
}

final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RuntimeTransportFailure] = []

    func append(_ failure: RuntimeTransportFailure) {
        lock.withLock { failures.append(failure) }
    }

    func snapshot() -> [RuntimeTransportFailure] {
        lock.withLock { failures }
    }
}

final class RecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func append() { lock.withLock { count += 1 } }
    func snapshot() -> Int { lock.withLock { count } }
}

final class NanosecondTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    var value: UInt64 { lock.withLock { current } }
    func advance(by amount: UInt64) { lock.withLock { current &+= amount } }
}
