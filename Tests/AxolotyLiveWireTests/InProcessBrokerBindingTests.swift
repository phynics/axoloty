// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyProtocol
import AxolotyTestBroker
import AxolotyTestSupport
import AxolotyWire
import Foundation
import Testing

/// Broker-backed coverage for the host MQTT transport boundary that needs no
/// container runtime, no Mosquitto, and no fixed port.
///
/// The in-process ``TestMQTTBroker`` is the default broker. The Mosquitto path
/// stays reachable through the shell runner for conformance, so the two are
/// held to one contract: both must satisfy the same suite.
struct InProcessBrokerBindingTests {
    private static let sourceID = UUID16(parsing: "66666666-6666-4666-8666-666666666666")!
    private static let peerID = UUID16(parsing: "77777777-7777-4777-8777-777777777777")!
    /// The canonical hyphenated form, because `UUID16` has no string accessor
    /// and string interpolation would emit its debug description.
    private static let peerIDString = "77777777-7777-4777-8777-777777777777"
    private static let fixtureID = "88888888-8888-4888-8888-888888888888"
    private static let externalRoute = "axoloty/live/external"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_MQTT_BINDING_NETWORK_LIVE"] != "1"))
    func bindingLifecycleAgainstInProcessBroker() async throws {
        let timeout = Duration.seconds(15)
        let firstBroker = TestMQTTBroker()
        let port = try firstBroker.start()
        var broker: TestMQTTBroker? = firstBroker
        defer { broker?.stop() }
        let namespace = "axoloty-inprocess-\(port)"
        let subjectInbox = FrameInbox()
        let peerInbox = FrameInbox()
        let subject = try makeBinding(port: port)
        let peer = try makeBinding(port: port)

        do {
            try await withTimeout("subject MQTTBinding start", timeout: timeout) {
                try await subject.start { frame in Task { await subjectInbox.append(frame) } }
            }
            try await withTimeout("peer MQTTBinding start", timeout: timeout) {
                try await peer.start { frame in Task { await peerInbox.append(frame) } }
            }
            try await withTimeout("subject profile subscriptions", timeout: timeout) {
                try await subject.activateProfileInterest(namespace: namespace)
            }
            try await withTimeout("peer profile subscriptions", timeout: timeout) {
                try await peer.activateProfileInterest(namespace: namespace)
            }

            let profileRoute = "coaty/3/\(namespace)/ADV:Identity/\(Self.peerIDString)"
            let profilePayload = Array("{\"object\":{\"coreType\":\"Identity\",\"objectType\":\"coaty.Identity\",\"objectId\":\"\(Self.fixtureID)\"}}".utf8)
            try await peer.perform(.publish(RuntimeOutboundMessage(route: profileRoute, payload: profilePayload)))
            try await waitUntil("profile receive", timeout: timeout) {
                await subjectInbox.contains { frame in
                    if case let .profile(route, payload, _) = frame {
                        return route == profileRoute && payload == profilePayload
                    }
                    return false
                }
            }

            let unrelatedRoute = "other/\(namespace)/not-coaty"
            let beforeUnrelated = await subjectInbox.count
            try await peer.perform(.publish(RuntimeOutboundMessage(
                route: unrelatedRoute,
                payload: Array("unrelated".utf8)
            )))
            try await Task.sleep(for: .milliseconds(250))
            #expect(await subjectInbox.count == beforeUnrelated, "unrelated MQTT routes must be filtered")

            let external = OwnedExternalRouteTransition(
                sourceID: Self.sourceID,
                actorID: Self.peerID,
                route: Array(Self.externalRoute.utf8)
            )
            try await subject.perform(.externalRouteActivated(external))
            let externalPayload = Array("{\"value\":42}".utf8)
            try await peer.perform(.publish(RuntimeOutboundMessage(
                route: Self.externalRoute,
                payload: externalPayload
            )))
            try await waitUntil("external route receive", timeout: timeout) {
                await subjectInbox.contains { frame in
                    if case let .externalIo(route, payload, _) = frame {
                        return route == Self.externalRoute && payload == externalPayload
                    }
                    return false
                }
            }

            let beforeDeactivation = await subjectInbox.count
            try await subject.perform(.externalRouteDeactivated(external))
            try await peer.perform(.publish(RuntimeOutboundMessage(
                route: Self.externalRoute,
                payload: Array("{\"value\":43}".utf8)
            )))
            try await Task.sleep(for: .milliseconds(250))
            #expect(await subjectInbox.count == beforeDeactivation, "a deactivated external route must be filtered")

            // Replace the broker on the same port to force a reconnect with no
            // container restart and no shell marker file.
            try await withTimeout("peer MQTTBinding stop for restart", timeout: timeout) { await peer.stop() }
            try await withTimeout("subject MQTTBinding stop for restart", timeout: timeout) { await subject.stop() }
            broker?.stop()
            let replacement = TestMQTTBroker(configuration: TestMQTTBroker.Configuration(port: port))
            broker = replacement
            try replacement.start()
            try await withTimeout("peer MQTTBinding restart", timeout: timeout) {
                try await peer.start { frame in Task { await peerInbox.append(frame) } }
                try await peer.activateProfileInterest(namespace: namespace)
            }
            try await withTimeout("subject MQTTBinding restart", timeout: timeout) {
                try await subject.start { frame in Task { await subjectInbox.append(frame) } }
                try await subject.activateProfileInterest(namespace: namespace)
            }
            let resumedRoute = "coaty/3/\(namespace)/ADV:Identity/\(Self.peerIDString)"
            try await peer.perform(.publish(RuntimeOutboundMessage(route: resumedRoute, payload: profilePayload)))
            try await waitUntil("post-restart profile receive", timeout: timeout) {
                await subjectInbox.contains { frame in
                    if case let .profile(route, payload, _) = frame {
                        return route == resumedRoute && payload == profilePayload
                    }
                    return false
                }
            }

            try await withTimeout("peer MQTTBinding stop", timeout: timeout) { await peer.stop() }
            try await withTimeout("subject MQTTBinding stop", timeout: timeout) { await subject.stop() }
        } catch {
            try? await withTimeout("peer MQTTBinding failure stop", timeout: timeout) { await peer.stop() }
            try? await withTimeout("subject MQTTBinding failure stop", timeout: timeout) { await subject.stop() }
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_MQTT_BINDING_NETWORK_LIVE"] != "1"))
    func willIsDeliveredThroughInProcessBroker() async throws {
        let timeout = Duration.seconds(15)
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }
        let willRoute = "axoloty/live/will"
        let willPayload = Array("gone".utf8)
        let observerInbox = FrameInbox()
        let observer = try makeBinding(port: port)
        let doomed = try makeBinding(port: port)
        defer {
            Task {
                await observer.stop()
                await doomed.stop()
            }
        }

        try await withTimeout("observer MQTTBinding start", timeout: timeout) {
            try await observer.start { frame in Task { await observerInbox.append(frame) } }
        }
        let established = Set(broker.connections().map(\.id))
        try await withTimeout("MQTTBinding start with a last will", timeout: timeout) {
            try await doomed.start(
                receive: { _ in },
                lastWill: RuntimeTransportLastWill(topic: willRoute, payload: willPayload)
            )
        }
        let doomedID = try #require(broker.connections().map(\.id).first { !established.contains($0) })

        let transition = OwnedExternalRouteTransition(
            sourceID: Self.sourceID,
            actorID: Self.peerID,
            route: Array(willRoute.utf8)
        )
        try await observer.perform(.externalRouteActivated(transition))
        try await waitUntil("will subscription", timeout: timeout) {
            broker.subscriptions().contains { $0.filter == willRoute }
        }

        try broker.injectDisconnect(connectionID: doomedID)
        try await waitUntil("will delivery", timeout: timeout) {
            await observerInbox.contains { frame in
                if case let .externalIo(route, payload, _) = frame {
                    return route == willRoute && payload == willPayload
                }
                return false
            }
        }
    }

    private func makeBinding(port: Int) throws -> MQTTBinding {
        try MQTTBinding(configuration: MQTTBindingConfiguration(
            host: "127.0.0.1",
            port: UInt16(port),
            connectionTimeoutMS: 10_000,
            operationTimeoutMS: 10_000
        ))
    }
}

private actor FrameInbox {
    private var frames: [RuntimeInboundFrame] = []

    func append(_ frame: RuntimeInboundFrame) {
        frames.append(frame)
    }

    var count: Int { frames.count }

    func contains(_ predicate: @Sendable (RuntimeInboundFrame) -> Bool) -> Bool {
        frames.contains(where: predicate)
    }
}
