// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Foundation
import Testing

/// Broker-backed coverage for the host MQTT transport boundary.
///
/// The test uses two real bindings. The second binding publishes frames so the
/// receive assertions cannot pass from local queue admission alone. The shell
/// runner restarts Mosquitto between the two binding sessions and retains both
/// the application log and an independent MQTT capture.
struct MQTTBindingNetworkTests {
    private static let sourceID = UUID16(parsing: "66666666-6666-4666-8666-666666666666")!
    private static let peerID = UUID16(parsing: "77777777-7777-4777-8777-777777777777")!
    private static let fixtureID = "88888888-8888-4888-8888-888888888888"
    private static let externalRoute = "axoloty/live/external"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_MQTT_BINDING_NETWORK_LIVE"] == "1"))
    func bindingNetworkLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let namespace = environment["WIRE_NAMESPACE"] ?? "axoloty-mqtt-binding"
        let timeout = Duration.seconds(30)
        let subjectInbox = FrameInbox()
        let peerInbox = FrameInbox()
        let subject = try makeBinding(environment: environment)
        let peer = try makeBinding(environment: environment)

        do {
            report("starting")
            try await withTimeout("subject MQTTBinding start", timeout: timeout) {
                try await subject.start { frame in
                    Task { await subjectInbox.append(frame) }
                }
            }
            try await withTimeout("peer MQTTBinding start", timeout: timeout) {
                try await peer.start { frame in
                    Task { await peerInbox.append(frame) }
                }
            }
            try await withTimeout("subject profile subscriptions", timeout: timeout) {
                try await subject.installSubscriptions(namespace: namespace)
            }
            try await withTimeout("peer profile subscriptions", timeout: timeout) {
                try await peer.installSubscriptions(namespace: namespace)
            }
            report("started", "namespace=\(namespace)")

            let profileRoute = "coaty/3/\(namespace)/ADV:Identity/\(Self.peerID)"
            let profilePayload = Array("{\"object\":{\"coreType\":\"Identity\",\"objectType\":\"coaty.Identity\",\"objectId\":\"\(Self.fixtureID)\"}}".utf8)
            try await peer.perform(.publish(RuntimeOutboundMessage(route: profileRoute, payload: profilePayload)))
            try await waitFor("profile receive", timeout: timeout) {
                await subjectInbox.contains { frame in
                    if case let .profile(route, payload, _) = frame {
                        return route == profileRoute && payload == profilePayload
                    }
                    return false
                }
            }
            report("profile-received", "route=\(profileRoute)")

            let unrelatedRoute = "other/\(namespace)/not-coaty"
            let beforeUnrelated = await subjectInbox.count
            try await peer.perform(.publish(RuntimeOutboundMessage(
                route: unrelatedRoute,
                payload: Array("unrelated".utf8)
            )))
            try await Task.sleep(for: .milliseconds(250))
            #expect(await subjectInbox.count == beforeUnrelated, "unrelated MQTT routes must be filtered")
            report("receive-filtered", "route=\(unrelatedRoute)")

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
            try await waitFor("external route receive", timeout: timeout) {
                await subjectInbox.contains { frame in
                    if case let .externalIo(route, payload, _) = frame {
                        return route == Self.externalRoute && payload == externalPayload
                    }
                    return false
                }
            }
            report("external-route-received", "route=\(Self.externalRoute)")

            let beforeDeactivation = await subjectInbox.count
            try await subject.perform(.externalRouteDeactivated(external))
            try await peer.perform(.publish(RuntimeOutboundMessage(
                route: Self.externalRoute,
                payload: Array("{\"value\":43}".utf8)
            )))
            try await Task.sleep(for: .milliseconds(250))
            #expect(await subjectInbox.count == beforeDeactivation, "deactivated external route must be filtered")
            report("external-route-deactivated", "route=\(Self.externalRoute)")

            if let ready = environment["WIRE_MQTT_BINDING_READY"] {
                try mark(ready)
                report("awaiting-broker-restart")
                try await waitForFile("broker restart marker", path: environment["WIRE_MQTT_BINDING_RESTARTED"], timeout: timeout)
                try? await withTimeout("subject MQTTBinding stop for restart", timeout: timeout) { await subject.stop() }
                try await withTimeout("subject MQTTBinding restart", timeout: timeout) {
                    try await subject.start { frame in
                        Task { await subjectInbox.append(frame) }
                    }
                    try await subject.installSubscriptions(namespace: namespace)
                }
                if let resubscribeReady = environment["WIRE_MQTT_BINDING_RESUBSCRIBE_READY"] {
                    try mark(resubscribeReady)
                }
                report("reconnected")
                try await waitFor("post-restart profile receive", timeout: timeout) {
                    await subjectInbox.contains { frame in
                        if case let .profile(route, payload, _) = frame {
                            return route.hasPrefix("coaty/3/\(namespace)/") &&
                                String(decoding: payload, as: UTF8.self).contains("wire-fixture")
                        }
                        return false
                    }
                }
                report("post-restart-received")
            }

            try await withTimeout("peer MQTTBinding stop", timeout: timeout) { await peer.stop() }
            try await withTimeout("subject MQTTBinding stop", timeout: timeout) { await subject.stop() }
            report("stopped")
        } catch {
            try? await withTimeout("peer MQTTBinding failure stop", timeout: timeout) { await peer.stop() }
            try? await withTimeout("subject MQTTBinding failure stop", timeout: timeout) { await subject.stop() }
            report("failed", "error=\(error)")
            throw error
        }
    }

    private func makeBinding(environment: [String: String]) throws -> MQTTBinding {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let operationTimeout = UInt32(environment["WIRE_MQTT_OPERATION_TIMEOUT_MS"] ?? "10000") ?? 1000
        return try MQTTBinding(configuration: MQTTBindingConfiguration(
            host: host,
            port: port,
            connectionTimeoutMS: 10_000,
            operationTimeoutMS: operationTimeout
        ))
    }

    private func waitFor(
        _ label: String,
        timeout: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await waitUntil(label, timeout: timeout) { await condition() }
    }

    private func waitForFile(
        _ label: String,
        path: String?,
        timeout: Duration
    ) async throws {
        guard let path, !path.isEmpty else {
            throw AxolotyError.invalidArgument(argument: "marker", reason: "missing \(label) path")
        }
        try await waitFor(label, timeout: timeout) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private func mark(_ path: String) throws {
        try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func report(_ state: String, _ detail: String = "") {
        let suffix = detail.isEmpty ? "" : ",\"detail\":\"\(detail.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        FileHandle.standardError.write(Data("{\"state\":\"\(state)\"\(suffix)}\n".utf8))
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
