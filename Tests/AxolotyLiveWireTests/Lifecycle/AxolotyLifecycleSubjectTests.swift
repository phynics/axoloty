// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Foundation
import Testing

/// Live lifecycle subjects for the modern host runtime.
///
/// These tests deliberately use only ``AxolotyRuntime`` and ``MQTTBinding``.
/// The shell runners keep the broker and proxy controls outside the subject;
/// the subject reports bounded state transitions as JSONL so the independent
/// MQTT capture can be correlated with application behavior.
struct AxolotyLifecycleSubjectTests {
    private static let identityID = UUID16(parsing: "44444444-4444-4444-8444-444444444444")!

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
            let requestReceipt = await runtime.request(.call(
                correlationID: correlation,
                operation: "wire-fixture-operation",
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 10_000
            ))
            guard requestReceipt == .accepted else {
                throw LifecycleFailure.requestRejected(requestReceipt)
            }
            try signalResponseReady(
                scenario: "duplicate-reply",
                operation: "wire-fixture-operation",
                correlationID: correlation
            )
            _ = try await nextEvent(&iterator, timeout: .seconds(10))
            report(state: "accepted", scenario: "duplicate-reply", extra: ["variant": "original"])
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(1))
                Issue.record("the duplicate Return was delivered to the runtime event stream")
            } catch is AsyncWaitTimeoutError {
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
            let requestReceipt = await runtime.request(.call(
                correlationID: correlation,
                operation: "wire-fixture-operation",
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 2_000
            ), nowMS: requestNowMS)
            guard requestReceipt == .accepted else {
                throw LifecycleFailure.requestRejected(requestReceipt)
            }
            try signalResponseReady(
                scenario: "late-reply",
                operation: "wire-fixture-operation",
                correlationID: correlation
            )
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(2.5))
                Issue.record("the deliberately late Return arrived before the request deadline")
            } catch is AsyncWaitTimeoutError {
                guard await runtime.expire(nowMS: requestNowMS &+ 2_500) else {
                    Issue.record("the request deadline did not expire")
                    throw LifecycleFailure.deadlineNotExpired
                }
                report(state: "gave-up", scenario: "late-reply")
            }
            do {
                _ = try await nextEvent(&iterator, timeout: .seconds(3))
                Issue.record("the late Return was delivered after expiry")
            } catch is AsyncWaitTimeoutError, is CancellationError {
                // The capture verifier separately proves that the responder
                // published the late Return on the wire. A timed read may
                // also cancel this iterator before the second read begins.
            }
            try await ModernConsumerSupport.awaitPeerAcknowledgement(
                environment: ProcessInfo.processInfo.environment,
                scenario: "late-reply",
                context: "correlationId=\(correlation)",
                timeout: .seconds(15)
            )
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
        let diagnostics = LifecycleDiagnosticsLog()
        await diagnostics.start(runtime)
        do {
            report(state: "ready", scenario: scenario)
            try await waitForState(.reconnecting, runtime: runtime, diagnostics: diagnostics)
            report(state: "offline", scenario: scenario)
            if publishAfterReconnect {
                let first = await runtime.publish(.advertise(queuedPayload(name: "first")))
                let second = await runtime.publish(.advertise(queuedPayload(name: "second")))
                guard first == .accepted, second == .accepted else {
                    throw LifecycleFailure.offlinePublicationRejected
                }
                report(state: "published-offline", scenario: scenario, extra: ["count": "2"])
            }
            try await waitForReconnectMarker(scenario: scenario)
            try await reconnectUntilRunning(runtime: runtime, diagnostics: diagnostics)
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
            await diagnostics.stop()
            await runtime.stop()
        } catch {
            await diagnostics.stop()
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
        var builder = try RuntimeBuilder(identity: identity, namespace: namespace)
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

    /// Drives `reconnect()` until the runtime is running again.
    ///
    /// The harness publishes its readiness marker once the broker container is
    /// back, which does not guarantee the broker is already accepting
    /// connections. A reconnect that loses that race leaves the runtime
    /// `.reconnecting` rather than failing it, so retrying is the caller's
    /// half of that contract -- a single attempt would report a broker that is
    /// merely slow as a dead runtime.
    private func reconnectUntilRunning(
        runtime: AxolotyRuntime,
        diagnostics: LifecycleDiagnosticsLog
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        var attempts = 0
        while true {
            await runtime.reconnect()
            attempts += 1
            let state = await runtime.state()
            if state == .running { return }
            guard clock.now < deadline else {
                let counters = await runtime.diagnosticsSnapshot()
                let recorded = await diagnostics.formatted()
                throw AxolotyError.runtime(
                    code: .timedOut,
                    reason: """
                        Gave up reconnecting after \(attempts) attempts; \
                        observed=\(state); counters=\(counters); diagnostics=\(recorded)
                        """
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func waitForState(
        _ expected: RuntimeState,
        runtime: AxolotyRuntime,
        diagnostics: LifecycleDiagnosticsLog
    ) async throws {
        do {
            try await waitUntil("runtime to enter \(expected) state", timeout: .seconds(60)) {
                await runtime.state() == expected
            }
        } catch {
            // The observed state separates the two ways this wait can fail: a
            // runtime still `.reconnecting` is stalled inside `reconnect()`,
            // while `.failed` means it gave up and will never retry. Without
            // this the timeout reports only that the state never changed,
            // which is true of both.
            let observed = await runtime.state()
            let counters = await runtime.diagnosticsSnapshot()
            let recorded = await diagnostics.formatted()
            throw AxolotyError.runtime(
                code: .timedOut,
                reason: """
                    Timed out waiting for runtime to enter \(expected) state; \
                    observed=\(observed); counters=\(counters); diagnostics=\(recorded)
                    """
            )
        }
    }

    private func waitForReconnectMarker(scenario: String) async throws {
        let path = ProcessInfo.processInfo.environment["WIRE_RECONNECT_READY"]
        guard let path, !path.isEmpty else { throw LifecycleFailure.reconnectHandshakeMissing }
        do {
            try await waitUntil("\(scenario) reconnect handshake marker", timeout: .seconds(60)) {
                FileManager.default.fileExists(atPath: path)
            }
        } catch {
            throw AxolotyError.runtime(
                code: .timedOut,
                reason: "Timed out waiting for \(scenario) reconnect marker at \(path); runtime state and diagnostics are emitted by the subject"
            )
        }
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
        try await nextValue(&iterator, timeout: timeout)
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

    private func signalResponseReady(
        scenario: String,
        operation: String,
        correlationID: UUID16
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WIRE_RESPONSE_READY"], !path.isEmpty else {
            throw LifecycleFailure.responseHandshakeMissing
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryPath = "\(path).tmp-\(ProcessInfo.processInfo.processIdentifier)"
        let document = "{\"phase\":\"response-ready\",\"scenario\":\"\(scenario)\",\"operation\":\"\(operation)\",\"correlationId\":\"\(correlationID)\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}\n"
        try Data(document.utf8).write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
        try FileManager.default.moveItem(
            at: URL(fileURLWithPath: temporaryPath),
            to: URL(fileURLWithPath: path)
        )
        reportPhase(
            scenario: scenario,
            phase: "response-ready",
            extra: [
                "operation": operation,
                "correlationId": String(describing: correlationID),
                "pid": String(ProcessInfo.processInfo.processIdentifier),
            ]
        )
    }

    private func reportPhase(
        scenario: String,
        phase: String,
        extra: [String: String] = [:]
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = [
            "\"phase\":\"\(phase)\"",
            "\"scenario\":\"\(scenario)\"",
            "\"at\":\"\(formatter.string(from: Date()))\"",
        ]
        for (key, value) in extra { fields.append("\"\(key)\":\"\(value)\"") }
        FileHandle.standardOutput.write(Data("{\(fields.joined(separator: ","))}\n".utf8))
    }
}

/// Records the runtime's diagnostic stream for the duration of one network
/// scenario.
///
/// A lifecycle timeout otherwise reports only that the runtime never reached
/// the expected state, which is equally true of a runtime stalled inside
/// `reconnect()` and one that failed terminally and stopped retrying. The
/// diagnostic stream carries the transport detail for both -- including the
/// terminal detail `failRuntime` emits -- so recording it turns that timeout
/// into a named cause.
private actor LifecycleDiagnosticsLog {
    /// Bounded like every other buffer the subject owns, so a scenario that
    /// stalls for its full deadline cannot accumulate diagnostics without
    /// limit. The newest entries are the ones that explain a timeout, so the
    /// oldest are dropped once full.
    private static let capacity = 32

    private var entries: [String] = []
    private var pump: Task<Void, Never>?

    /// Begins recording. The runtime exposes a single diagnostic stream and
    /// the subject is its only consumer.
    func start(_ runtime: AxolotyRuntime) async {
        guard pump == nil else { return }
        let stream = await runtime.diagnostics()
        pump = Task { [weak self] in
            for await diagnostic in stream {
                await self?.append("\(diagnostic.kind.rawValue)=\(diagnostic.detail)")
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    func formatted() -> String {
        entries.isEmpty ? "none" : entries.joined(separator: " | ")
    }

    private func append(_ entry: String) {
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append(entry)
    }
}

private enum LifecycleFailure: Error {
    case invalidProbe
    case deadlineNotExpired
    case offlinePublicationRejected
    case reconnectHandshakeMissing
    case requestRejected(RuntimeReceipt)
    case responseHandshakeMissing
}
