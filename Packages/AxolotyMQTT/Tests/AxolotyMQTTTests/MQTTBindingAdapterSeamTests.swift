// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import Testing
@testable import AxolotyMQTT

@Suite("MQTT binding adapter seam")
struct MQTTBindingAdapterSeamTests {
    @Test("identity last will is passed to the MQTT adapter and omitted without one")
    func lifecycleLastWill() async throws {
        let will = RuntimeTransportLastWill(
            topic: "coaty/3/node/DAD/11111111-2222-4333-8444-555555555555",
            payload: Array("{\"objectIds\":[\"11111111-2222-4333-8444-555555555555\"]}".utf8)
        )

        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        try await binding.start(receive: { _ in }, lastWill: will)
        #expect(client.lastWill() == will)
        await binding.stop()

        let noWillDelegate = RuntimeMQTTDelegate()
        let noWillClient = FakeMQTTClient(delegate: noWillDelegate, connectsImmediately: true)
        let noWillBinding = try makeBinding(client: noWillClient, delegate: noWillDelegate)
        try await noWillBinding.start(receive: { _ in }, lastWill: nil)
        #expect(noWillClient.lastWill() == nil)
        await noWillBinding.stop()
    }

    @Test("start and stop own the adapter lifecycle")
    func startAndStop() async throws {
        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)

        let recorder = FrameRecorder()
        try await binding.start { recorder.append($0) }
        #expect(client.connectCount() == 1)
        await binding.stop()
        #expect(client.disconnectCount() == 1)

        // Stop releases callback admission. A late callback from the old
        // connection must not reach the application.
        client.emit(topic: "late", payload: [UInt8(1)])
        #expect(recorder.snapshot().isEmpty)
    }

    @Test("callbacks copy payloads and admit only active profile or subscribed external routes")
    func callbackCopyingAndFiltering() async throws {
        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        let recorder = FrameRecorder()

        try await binding.start { recorder.append($0) }
        try await binding.installSubscriptions(namespace: "node")
        let profile = "coaty/3/node/IOV/00000000-0000-4000-8000-000000000001"
        var payload: [UInt8] = [1, 2, 3]
        client.emit(topic: profile, payload: payload)
        payload[0] = 9
        client.emit(topic: "outside/topic", payload: [UInt8(4)])
        let profileFrames = recorder.snapshot()
        #expect(profileFrames.count == 1)
        if case let .profile(route, copiedPayload, _) = profileFrames[0] {
            #expect(route == profile)
            #expect(copiedPayload == [1, 2, 3])
        } else {
            Issue.record("expected an admitted profile frame")
        }

        try await binding.perform(.externalRouteActivated(transition("outside/topic")))
        client.emit(topic: "outside/topic", payload: [UInt8(5), UInt8(6)])
        let frames = recorder.snapshot()
        #expect(frames.count == 2)
        if case let .externalIo(route, copiedPayload, _) = frames.last {
            #expect(route == "outside/topic")
            #expect(copiedPayload == [5, 6])
        } else {
            Issue.record("expected an admitted external route frame")
        }
    }

    @Test("publish, subscribe, and unsubscribe failures map to network errors")
    func operationFailuresMapToNetworkErrors() async throws {
        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        try await binding.start { _ in }

        client.setPublishError(.publish)
        await expectNetwork {
            try await binding.perform(.publish(RuntimeOutboundMessage(route: "route", payload: [1])))
        }

        client.setSubscribeError(.subscribe)
        await expectNetwork {
            try await binding.installSubscriptions(namespace: "node")
        }

        // Install one route successfully so removeSubscriptions exercises the
        // unsubscribe path and its first-error preservation.
        client.setSubscribeError(nil)
        try await binding.perform(.externalRouteActivated(transition("external")))
        client.setUnsubscribeError(.unsubscribe)
        await expectNetwork {
            try await binding.removeSubscriptions(namespace: "node")
        }
    }

    @Test("external route references subscribe once and rollback failed transitions")
    func externalRouteReferencesAndRollback() async throws {
        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        try await binding.start { _ in }

        let route = transition("external")
        try await binding.perform(.externalRouteActivated(route))
        try await binding.perform(.externalRouteActivated(route))
        #expect(client.subscribeTopics().filter { $0 == "external" }.count == 1)
        try await binding.perform(.externalRouteDeactivated(route))
        #expect(client.unsubscribeTopics().filter { $0 == "external" }.isEmpty)
        try await binding.perform(.externalRouteDeactivated(route))
        #expect(client.unsubscribeTopics().filter { $0 == "external" }.count == 1)

        client.setSubscribeError(.subscribe)
        await expectNetwork {
            try await binding.perform(.externalRouteActivated(transition("rollback")))
        }
        client.setSubscribeError(nil)
        try await binding.perform(.externalRouteActivated(transition("rollback")))
        #expect(client.subscribeTopics().filter { $0 == "rollback" }.count == 2)

        client.setUnsubscribeError(.unsubscribe)
        await expectNetwork {
            try await binding.perform(.externalRouteDeactivated(transition("rollback")))
        }
        client.setUnsubscribeError(nil)
        try await binding.perform(.externalRouteDeactivated(transition("rollback")))
        #expect(client.unsubscribeTopics().filter { $0 == "rollback" }.count == 2)
    }

    @Test("a completion from an old transport epoch cannot resurrect an external route")
    func staleEpochDoesNotResurrectRoute() async throws {
        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        try await binding.start { _ in }
        client.blockNextSubscribe()
        let pending = Task {
            try await binding.perform(.externalRouteActivated(transition("stale")))
        }
        await client.waitForBlockedSubscribe()
        try await binding.removeSubscriptions(namespace: "node")
        client.releaseBlockedSubscribe()
        try await pending.value

        // The stale completion was ignored. A new activation must issue a new
        // subscription instead of treating the old record as subscribed.
        try await binding.perform(.externalRouteActivated(transition("stale")))
        #expect(client.subscribeTopics().filter { $0 == "stale" }.count == 2)
    }

    @Test("start timeout maps to brokerUnavailable and failure callback preserves transport errors")
    func timeoutAndFailureMapping() async throws {
        let timeoutDelegate = RuntimeMQTTDelegate()
        let timeoutClient = FakeMQTTClient(delegate: timeoutDelegate, connectsImmediately: false)
        let timeoutBinding = try makeBinding(
            client: timeoutClient,
            delegate: timeoutDelegate,
            connectionTimeoutMS: 1
        )
        do {
            try await timeoutBinding.start { _ in }
            Issue.record("expected start timeout")
        } catch let error as AxolotyError {
            guard case let .runtime(code, _) = error else {
                Issue.record("expected runtime timeout, got \(error)")
                return
            }
            #expect(code == .brokerUnavailable)
        }

        let delegate = RuntimeMQTTDelegate()
        let client = FakeMQTTClient(delegate: delegate, connectsImmediately: true)
        let binding = try makeBinding(client: client, delegate: delegate)
        let failure = ErrorRecorder()
        await binding.setFailureHandler { failure.record($0) }
        try await binding.start { _ in }
        client.emitFailure(FakeError.connection)
        let transportFailure = failure.value() as? RuntimeTransportFailure
        #expect(transportFailure?.code == .brokerUnavailable)
        #expect(transportFailure?.detail.isEmpty == false)
    }

    private func makeBinding(
        client: FakeMQTTClient,
        delegate: RuntimeMQTTDelegate,
        connectionTimeoutMS: UInt32 = 100
    ) throws -> MQTTBinding {
        let configuration = try MQTTBindingConfiguration(connectionTimeoutMS: connectionTimeoutMS)
        return MQTTBinding(configuration: configuration, client: client, delegate: delegate)
    }

    private func transition(_ route: String) -> OwnedExternalRouteTransition {
        OwnedExternalRouteTransition(sourceID: .zero, actorID: .zero, route: Array(route.utf8))
    }

    private func expectNetwork(
        _ operation: () async throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await operation()
            Issue.record("expected network failure", sourceLocation: sourceLocation)
        } catch let error as AxolotyError {
            guard case .network = error else {
                Issue.record("expected network error, got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("expected AxolotyError.network, got \(error)", sourceLocation: sourceLocation)
        }
    }
}

private enum FakeError: Error, Equatable {
    case publish, subscribe, unsubscribe, connection
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RuntimeInboundFrame] = []

    func append(_ value: RuntimeInboundFrame) {
        lock.lock(); values.append(value); lock.unlock()
    }

    func snapshot() -> [RuntimeInboundFrame] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ value: Error) {
        lock.lock(); error = value; lock.unlock()
    }

    func value() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}

private final class FakeMQTTClient: RuntimeMQTTClientAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private let delegate: RuntimeMQTTDelegate
    private let connectsImmediately: Bool
    private var blockedSubscribeContinuation: CheckedContinuation<Void, Never>?
    private var blockedSubscribeReady = false
    private var connectCountValue = 0
    private var disconnectCountValue = 0
    private var subscribeTopicsValue: [String] = []
    private var unsubscribeTopicsValue: [String] = []
    private var publishError: FakeError?
    private var subscribeError: FakeError?
    private var unsubscribeError: FakeError?
    private var shouldBlockNextSubscribe = false
    private var lastWillValue: RuntimeTransportLastWill?

    init(delegate: RuntimeMQTTDelegate, connectsImmediately: Bool) {
        self.delegate = delegate
        self.connectsImmediately = connectsImmediately
    }

    func connectCount() -> Int { locked { connectCountValue } }
    func disconnectCount() -> Int { locked { disconnectCountValue } }
    func subscribeTopics() -> [String] { locked { subscribeTopicsValue } }
    func unsubscribeTopics() -> [String] { locked { unsubscribeTopicsValue } }
    func lastWill() -> RuntimeTransportLastWill? { locked { lastWillValue } }
    func setPublishError(_ error: FakeError?) { locked { publishError = error } }
    func setSubscribeError(_ error: FakeError?) { locked { subscribeError = error } }
    func setUnsubscribeError(_ error: FakeError?) { locked { unsubscribeError = error } }
    func blockNextSubscribe() { locked { shouldBlockNextSubscribe = true } }

    func connect(will: RuntimeTransportLastWill?) {
        locked { connectCountValue += 1 }
        locked { lastWillValue = will }
        if connectsImmediately { delegate.runtimeMQTTClientDidBecomeOnline() }
    }

    func disconnect() async {
        locked { disconnectCountValue += 1 }
    }

    func publish(topic: String, payload: [UInt8]) async throws {
        if let error = locked({ publishError }) { throw error }
    }

    @MainActor
    func subscribe(_ topic: String) async throws {
        let shouldBlock = locked {
            subscribeTopicsValue.append(topic)
            let value = shouldBlockNextSubscribe
            shouldBlockNextSubscribe = false
            return value
        }
        if shouldBlock {
            await withCheckedContinuation { continuation in
                locked {
                    blockedSubscribeReady = true
                    blockedSubscribeContinuation = continuation
                }
            }
        }
        if let error = locked({ subscribeError }) { throw error }
    }

    @MainActor
    func unsubscribe(_ topic: String) async throws {
        locked { unsubscribeTopicsValue.append(topic) }
        if let error = locked({ unsubscribeError }) { throw error }
    }

    func emit(topic: String, payload: [UInt8]) {
        delegate.runtimeMQTTClientDidReceive(topic: topic, payload: payload)
    }

    func emitFailure(_ error: Error) {
        delegate.runtimeMQTTClientDidFail(error)
    }

    func waitForBlockedSubscribe() async {
        while !locked({ blockedSubscribeReady }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseBlockedSubscribe() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in
            blockedSubscribeReady = false
            let value = blockedSubscribeContinuation
            blockedSubscribeContinuation = nil
            return value
        }
        continuation?.resume()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
