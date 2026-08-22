// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import Testing

/// Live lifecycle subjects for the modern host runtime.
///
/// These tests deliberately use only ``AxolotyRuntime`` and ``MQTTBinding``.
/// The shell runners keep the broker and proxy controls outside the subject;
/// the subject reports bounded state transitions as JSONL so the independent
/// MQTT capture can be correlated with application behavior.
@MainActor
struct AxolotyLifecycleSubjectTests {
    private static let identityID = UUID16(parsing: "44444444-4444-4444-8444-444444444444")!
    private static let queuedFirstSourceID = UUID16(parsing: "66666666-6666-4666-8666-666666666661")!
    private static let queuedSecondSourceID = UUID16(parsing: "66666666-6666-4666-8666-666666666662")!

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_DUPLICATE_REPLY_LIVE"] == "1"))
    func duplicateReply() async throws {
        let correlation = UUID16(parsing: "55555555-5555-4555-8555-555555555555")!
        let (runtime, stream) = try await makeRuntime(
            scenario: "duplicate-reply",
            selector: .correlatedResponse(capability: .returnEvent, correlationID: correlation)
        )
        do {
            report(state: "ready", scenario: "duplicate-reply")
            var iterator = stream.makeAsyncIterator()
            _ = await runtime.request(.call(
                correlationID: correlation,
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 10_000
            ))
            _ = try await nextEvent(&iterator, timeout: .seconds(10))
            report(state: "accepted", scenario: "duplicate-reply", extra: ["variant": "original"])
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(1))
                Issue.record("the duplicate Return was delivered to the runtime event stream")
            } catch is LifecycleTimeout {
                report(state: "ignored", scenario: "duplicate-reply", extra: ["variant": "duplicate"])
            }
            report(state: "done", scenario: "duplicate-reply")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_LATE_REPLY_LIVE"] == "1"))
    func lateReply() async throws {
        let correlation = UUID16(parsing: "55555555-5555-4555-8555-555555555556")!
        let (runtime, stream) = try await makeRuntime(
            scenario: "late-reply",
            selector: .correlatedResponse(capability: .returnEvent, correlationID: correlation)
        )
        do {
            report(state: "ready", scenario: "late-reply")
            var iterator = stream.makeAsyncIterator()
            let requestNowMS = Self.monotonicNowMS()
            _ = await runtime.request(.call(
                correlationID: correlation,
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 2_000
            ), nowMS: requestNowMS)
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(2.5))
                Issue.record("the deliberately late Return arrived before the request deadline")
            } catch is LifecycleTimeout {
                guard await runtime.expire(nowMS: requestNowMS &+ 2_500) else {
                    Issue.record("the request deadline did not expire")
                    throw LifecycleFailure.deadlineNotExpired
                }
                report(state: "gave-up", scenario: "late-reply")
            }
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(3))
                Issue.record("the late Return was delivered after expiry")
            } catch is LifecycleTimeout {
                // The capture verifier separately proves that the responder
                // published the late Return on the wire.
            }
            report(state: "done", scenario: "late-reply")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_OFFLINE_QUEUEING_LIVE"] == "1"))
    func offlineQueueing() async throws {
        try await runNetworkScenario(named: "offline-queueing", publishAfterReconnect: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_RECONNECT_RESUBSCRIBE_LIVE"] == "1"))
    func reconnectResubscribe() async throws {
        try await runNetworkScenario(named: "reconnect-resubscribe", publishAfterReconnect: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_BROKER_RESTART_LIVE"] == "1"))
    func brokerRestart() async throws {
        try await runNetworkScenario(named: "broker-restart", publishAfterReconnect: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_CLEAN_SESSION_LIVE"] == "1"))
    func cleanSession() async throws {
        try await runNetworkScenario(named: "clean-session", publishAfterReconnect: false)
    }

    private func runNetworkScenario(named scenario: String, publishAfterReconnect: Bool) async throws {
        let (runtime, stream) = try await makeRuntime(
            scenario: scenario,
            selector: .advertise(objectType: "com.coaty.test.WireFixture")
        )
        do {
            report(state: "ready", scenario: scenario)
            try await waitForState(.reconnecting, runtime: runtime)
            report(state: "offline", scenario: scenario)
            if publishAfterReconnect {
                let first = await runtime.publish(RuntimeOperation.advertise(
                    sourceID: Self.queuedFirstSourceID,
                    payload: queuedPayload(name: "first")
                ))
                let second = await runtime.publish(RuntimeOperation.advertise(
                    sourceID: Self.queuedSecondSourceID,
                    payload: queuedPayload(name: "second")
                ))
                guard first == .accepted, second == .accepted else {
                    throw LifecycleFailure.offlinePublicationRejected
                }
                report(state: "published-offline", scenario: scenario, extra: ["count": "2"])
            }
            try await waitForReconnectMarker()
            await runtime.reconnect()
            try await waitForState(.running, runtime: runtime)
            report(state: "reconnected", scenario: scenario)

            if !publishAfterReconnect {
                var iterator = stream.makeAsyncIterator()
                let event = try await nextEvent(&iterator, timeout: .seconds(60))
                guard String(decoding: event.value, as: UTF8.self).contains("com.coaty.test.WireFixture") else {
                    throw LifecycleFailure.invalidProbe
                }
                report(state: "probe-received", scenario: scenario, extra: ["name": "wire-fixture"])
            }
            report(state: "done", scenario: scenario)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func makeRuntime(
        scenario: String,
        selector: RuntimeEventSelector
    ) async throws -> (AxolotyRuntime, RuntimeEventStream) {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let identity = try RuntimeIdentity(id: Self.identityID, name: "axoloty-lifecycle-subject")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: namespace)
        let stream = try builder.events(matching: selector, buffering: .dropOldest(capacity: 16))
        let definition = try builder.finish()
        let binding = try MQTTBinding(configuration: try MQTTBindingConfiguration(host: host, port: port))
        let runtime = AxolotyRuntime(definition: definition, transport: binding)
        do {
            try await runtime.start()
        } catch {
            await runtime.stop()
            throw error
        }
        _ = scenario
        return (runtime, stream)
    }

    private func waitForState(_ expected: RuntimeState, runtime: AxolotyRuntime) async throws {
        for _ in 0..<240 {
            if await runtime.state() == expected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LifecycleTimeout()
    }

    private func waitForReconnectMarker() async throws {
        let path = ProcessInfo.processInfo.environment["WIRE_RECONNECT_READY"]
        guard let path, !path.isEmpty else { throw LifecycleFailure.reconnectHandshakeMissing }
        for _ in 0..<1_200 {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LifecycleTimeout()
    }

    private func queuedPayload(name: String) -> [UInt8] {
        let objectID = name == "first"
            ? "66666666-6666-4666-8666-666666666661"
            : "66666666-6666-4666-8666-666666666662"
        return Array("{\"object\":{\"objectId\":\"\(objectID)\",\"coreType\":\"CoatyObject\",\"objectType\":\"com.coaty.test.WireQueuedFixture\",\"name\":\"\(name)\"}}".utf8)
    }

    private static func monotonicNowMS() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func nextEvent(
        _ iterator: inout AsyncStream<RuntimeEventValue>.Iterator,
        timeout: Duration
    ) async throws -> RuntimeEventValue {
        let box = EventIteratorBox(iterator)
        defer { iterator = box.iterator }
        return try await withThrowingTaskGroup(of: RuntimeEventValue?.self) { group in
            group.addTask { await box.iterator.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LifecycleTimeout()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw LifecycleTimeout() }
            return value
        }
    }

    private func report(state: String, scenario: String, extra: [String: String] = [:]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = [
            "\"state\":\"\(state)\"",
            "\"scenario\":\"\(scenario)\"",
            "\"at\":\"\(formatter.string(from: Date()))\"",
        ]
        for (key, value) in extra { fields.append("\"\(key)\":\"\(value)\"") }
        FileHandle.standardOutput.write(Data("{\(fields.joined(separator: ","))}\n".utf8))
    }
}

private struct LifecycleTimeout: Error {}

private enum LifecycleFailure: Error {
    case invalidProbe
    case deadlineNotExpired
    case offlinePublicationRejected
    case reconnectHandshakeMissing
}

private final class EventIteratorBox: @unchecked Sendable {
    var iterator: AsyncStream<RuntimeEventValue>.Iterator

    init(_ iterator: AsyncStream<RuntimeEventValue>.Iterator) {
        self.iterator = iterator
    }
}
