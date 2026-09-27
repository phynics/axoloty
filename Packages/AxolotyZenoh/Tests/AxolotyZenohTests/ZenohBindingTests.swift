// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Foundation

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire
@testable import AxolotyZenoh
import AxolotyZenohCore

@Suite("Zenoh runtime transport")
struct ZenohBindingTests {
    @Test("starts and stops one serialized session")
    func startAndStop() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)

        try await binding.start { _ in }
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

        await #expect(throws: AxolotyError.self) {
            try await binding.activateProfileInterest(namespace: "node")
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

    @Test("forwards owned failures to the registered runtime handler")
    func failureForwarding() async throws {
        let session = RecordingZenohSession()
        let binding = try makeBinding(session: session)
        let recorder = FailureRecorder()
        await binding.setFailureHandler { recorder.append($0) }
        try await binding.start { _ in }
        session.closeResult = .transportError

        await binding.stop()

        #expect(recorder.snapshot() == [
            RuntimeTransportFailure(code: .brokerUnavailable, detail: "Zenoh session close failed in the Zenoh transport"),
        ])
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

    private func makeBinding(session: any ZenohBindingSession) throws -> ZenohBinding {
        let configuration = try ZenohBindingConfiguration()
        return ZenohBinding(configuration: configuration, session: session)
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

private final class RecordingZenohSession: ZenohBindingSession {
    enum Operation: Equatable {
        case open([UInt8])
        case close
        case publish([UInt8], [UInt8])
        case subscribe([UInt8], id: Int)
        case unsubscribe(Int)
    }

    private(set) var operations: [Operation] = []
    private var nextID = 0
    var closeResult: ZenohResult = .success
    var unsubscribeResult: ZenohResult = .success
    var subscribeFailureOnAttempt: Int?

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
        return .success
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
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RuntimeTransportFailure] = []

    func append(_ failure: RuntimeTransportFailure) {
        lock.withLock { failures.append(failure) }
    }

    func snapshot() -> [RuntimeTransportFailure] {
        lock.withLock { failures }
    }
}
