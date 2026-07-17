// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Axoloty (modern Swift) as the Call/Return initiator against pinned
/// CoatyJS 2.4.0 acting as a (deliberately misbehaving, for these two
/// scenarios) responder. This is the request/reply half of the lifecycle
/// catalog's `duplicate-reply` and `late-reply` scenarios: see
/// `Tests/WireCompatibility/Reverse/coatyjs-core-consumer.js` for the
/// responder side, which sends a genuine second wire `Return` (duplicate) or
/// deliberately withholds its `Return` past the point this test gives up
/// (late).
///
/// Every state transition is written as a JSONL line to stdout so the
/// orchestrating shell script (`run-lifecycle-call-return.sh`) and the
/// retained `.testing/wire` application log can be cross-referenced against
/// the independent MQTT capture without inferring timing from prose.
@MainActor
struct AxolotyLifecycleSubjectTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_DUPLICATE_REPLY_LIVE"] == "1"))
    func duplicateReply() async throws {
        let (container, manager) = try makeManager()
        defer { container.shutdown() }
        try await container.startAndWaitUntilReady()

        let stream = try await manager.publishCall(CallEvent.with(
            operation: "wire-fixture-operation",
            parameters: ["operand": AnyCodable(7)]
        ))
        var iterator = await stream.makeAsyncIteratorAndWait()
        report(state: "ready", scenario: "duplicate-reply")

        // Real application-level duplicate handling: Axoloty's EventHub does
        // not itself deduplicate Return events by correlationId (there is no
        // such filter in CM+Publish.swift's responseStream/publishWithResponse),
        // so a correct caller must do it. This loop is exactly that caller
        // logic, not a shortcut around the library.
        var acceptedVariant: String?
        var ignoredVariant: String?
        var accepted = false
        for _ in 0 ..< 2 {
            let response = try await nextResponse(&iterator, timeout: .seconds(5))
            let variant = try decodeVariant(from: response)
            if !accepted {
                accepted = true
                acceptedVariant = variant
                report(state: "accepted", scenario: "duplicate-reply", extra: ["variant": variant])
            } else {
                ignoredVariant = variant
                report(state: "ignored", scenario: "duplicate-reply", extra: ["variant": variant])
            }
        }

        #expect(acceptedVariant == "original")
        #expect(ignoredVariant == "duplicate")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_LATE_REPLY_LIVE"] == "1"))
    func lateReply() async throws {
        let (container, manager) = try makeManager()
        defer { container.shutdown() }
        try await container.startAndWaitUntilReady()

        let stream = try await manager.publishCall(CallEvent.with(
            operation: "wire-fixture-operation",
            parameters: ["operand": AnyCodable(7)]
        ))
        var iterator = await stream.makeAsyncIteratorAndWait()
        report(state: "ready", scenario: "late-reply")

        // A deliberately short deadline: CoatyJS's responder (see
        // LIFECYCLE_LATE_REPLY_DELAY_MS, default 4s) waits well past this
        // before publishing its Return. Timing out here and letting the
        // enclosing task group cancel the pending `iterator.next()` task
        // exercises the real give-up path: EventStream.Iterator.next()'s
        // onCancel calls continuation.finish(), which (once it's the last
        // consumer) drives CM+Publish.swift's responseStream onLast handler
        // to release/unsubscribe the correlated response topic. A Return
        // published after that point cannot reach this process even in
        // principle -- there is no longer a live subscription for it.
        do {
            _ = try await nextResponse(&iterator, timeout: .seconds(2))
            Issue.record("Expected the Call to time out before CoatyJS's deliberately late Return")
        } catch is TimeoutGivingUp {
            report(state: "gave-up", scenario: "late-reply")
        }

        // Give CoatyJS's later Return (published on its own delayed timer)
        // time to actually reach the broker, so the independent MQTT capture
        // this scenario is verified against has a genuine late PUBLISH to
        // compare timestamps with -- not just an absence of one.
        try await _Concurrency.Task.sleep(for: .seconds(5))
        report(state: "done", scenario: "late-reply")
    }

    // MARK: - Network-failure scenarios (driven through tcp_proxy.py).
    //
    // These four tests are the Axoloty-subject half of the lifecycle
    // catalog's connectivity scenarios. The orchestrating script
    // (run-lifecycle-network.sh) watches the JSONL state lines below and
    // severs/restores the TCP path (or stops/starts the broker itself) at
    // the documented points; the subject only ever observes its own
    // communication state stream and reports transitions. Assertions about
    // what actually crossed the wire live in verify-lifecycle-network.py,
    // against the independent MQTT capture.

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_OFFLINE_QUEUEING_LIVE"] == "1"))
    func offlineQueueing() async throws {
        let (container, manager) = try makeManager()
        defer { container.shutdown() }
        try await container.startAndWaitUntilReady()

        let states = await manager.observeCommunicationStateStream()
        var stateIterator = await states.makeAsyncIteratorAndWait()
        report(state: "ready", scenario: "offline-queueing")

        try await waitForState(.offline, &stateIterator, scenario: "offline-queueing")
        report(state: "offline", scenario: "offline-queueing")

        // Published while provably offline: CommunicationManager.publish
        // appends to deferredPublications and flushes them, in order, on the
        // next online transition. The wire capture (which bypasses the
        // severed proxy) proves each label then appears exactly once.
        for label in ["first", "second"] {
            let object = CoatyObject(
                coreType: .CoatyObject,
                objectType: "com.coaty.test.WireQueuedFixture",
                objectId: CoatyUUID(),
                name: label
            )
            try manager.publishAdvertise(AdvertiseEvent.with(object: object))
        }
        report(state: "published-offline", scenario: "offline-queueing")

        try await waitForState(.online, &stateIterator, scenario: "offline-queueing")
        report(state: "reconnected", scenario: "offline-queueing")

        // publish is fire-and-forget (see AxolotyAdvertiseProducerTests);
        // give the flushed queue time to reach the broker before shutdown.
        try await _Concurrency.Task.sleep(for: .seconds(2))
        report(state: "done", scenario: "offline-queueing")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_RECONNECT_RESUBSCRIBE_LIVE"] == "1"))
    func reconnectResubscribe() async throws {
        try await runReconnectProbeScenario(named: "reconnect-resubscribe")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_BROKER_RESTART_LIVE"] == "1"))
    func brokerRestart() async throws {
        try await runReconnectProbeScenario(named: "broker-restart")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_LIFECYCLE_CLEAN_SESSION_LIVE"] == "1"))
    func cleanSession() async throws {
        // Identical subject behavior to reconnect-resubscribe: Axoloty always
        // connects with cleanSession: true (MQTTNIOClient.performConnect), so
        // the subscription being restored after reconnect is the coordinator
        // genuinely re-subscribing, not broker session state. The proxy's
        // CONNACK log (verified in verify-lifecycle-network.py) proves the
        // broker reported sessionPresent=false on the reconnect handshake.
        try await runReconnectProbeScenario(named: "clean-session")
    }

    /// Shared subject flow for the three scenarios whose wire observation is
    /// "a subscription survives a connectivity interruption": subscribe,
    /// report ready, wait out an orchestrated offline/online cycle, then
    /// require a genuinely decoded post-reconnect Advertise probe published
    /// by pinned CoatyJS 2.4.0.
    private func runReconnectProbeScenario(named scenario: String) async throws {
        let (container, manager) = try makeManager()
        defer { container.shutdown() }
        try await container.startAndWaitUntilReady()

        let advertises = try await manager.observeAdvertiseStream(
            withObjectType: "com.coaty.test.WireFixture"
        )
        var advertiseIterator = await advertises.makeAsyncIteratorAndWait()
        let states = await manager.observeCommunicationStateStream()
        var stateIterator = await states.makeAsyncIteratorAndWait()
        report(state: "ready", scenario: scenario)

        try await waitForState(.offline, &stateIterator, scenario: scenario)
        report(state: "offline", scenario: scenario)

        try await waitForState(.online, &stateIterator, scenario: scenario)
        report(state: "reconnected", scenario: scenario)

        // The orchestrator publishes the CoatyJS probe only after seeing
        // "reconnected", so receiving it here proves the re-subscription
        // (SubscriptionCoordinator.setOnline) actually happened on the new
        // connection -- with cleanSession: true there is no broker-side
        // session for the old subscription to survive in.
        // Generous deadline: the probe is a freshly spawned node process
        // (pinned @coaty/core), whose cold start alone has been observed to
        // take ~20s on this harness's hosts.
        let probe = try await nextAdvertise(&advertiseIterator, timeout: .seconds(60))
        #expect(probe.object.objectType == "com.coaty.test.WireFixture")
        #expect(probe.object.name == "wire-fixture")
        report(state: "probe-received", scenario: scenario, extra: ["name": probe.object.name])
        report(state: "done", scenario: scenario)
    }

    private func waitForState(
        _ target: CommunicationState,
        _ iterator: inout EventStream<CommunicationState>.Iterator,
        scenario: String
    ) async throws {
        // The state stream replays the current state to a new iterator, so
        // this loop tolerates an immediate non-target value and simply waits
        // until the orchestrated transition genuinely happens.
        let box = StateIteratorBox(iterator)
        defer { iterator = box.iterator }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let state = await box.iterator.next() {
                    if state == target {
                        return
                    }
                }
                throw TimeoutGivingUp()
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: .seconds(60))
                throw TimeoutGivingUp()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func makeManager() throws -> (container: Container, communication: CommunicationManager) {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let common = try CommonOptions(agentIdentity: [
            "name": "axoloty-lifecycle-subject",
            "objectId": #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444")),
        ])
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                common: common,
                communication: CommunicationOptions(
                    namespace: namespace,
                    mqttClientOptions: MQTTClientOptions(host: host, port: port),
                    shouldAutoStart: false
                )
            )
        )
        guard let communication = container.communicationManager else {
            throw AxolotyError.InvalidConfiguration("Container did not resolve a communication manager")
        }
        return (container, communication)
    }

    private func decodeVariant(from response: ResponseEventSnapshot) throws -> String {
        #expect(response.eventType == "RTN")
        let payload = try #require(String(data: response.payload, encoding: .utf8))
        let event: ReturnEvent = try #require(PayloadCoder.decode(payload))
        let result = try #require(event.data.result?.value as? [String: Any])
        return try #require(result["variant"] as? String)
    }

    private func report(state: String, scenario: String, extra: [String: String] = [:]) {
        // A UTC wall-clock timestamp on every state line, with the same
        // format as the capture probe's `capturedAt` (see mqtt_capture.py),
        // so verify-lifecycle-call-return.py can genuinely compare wire
        // timing against subject timing instead of trusting prose.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = [
            "\"state\":\"\(state)\"",
            "\"scenario\":\"\(scenario)\"",
            "\"at\":\"\(formatter.string(from: Date()))\"",
        ]
        for (key, value) in extra {
            fields.append("\"\(key)\":\"\(value)\"")
        }
        // The network-scenario orchestrator tails this process's redirected
        // stdout to time its sever/restore commands, so each state line is
        // written as an unbuffered FileHandle syscall: file-backed stdio
        // would hold block-buffered lines until process exit, and Swift 6
        // rejects touching C's shared `stdout` for an explicit fflush.
        let line = "{\(fields.joined(separator: ","))}\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

private struct TimeoutGivingUp: Swift.Error {}

private final class StateIteratorBox: @unchecked Sendable {
    var iterator: EventStream<CommunicationState>.Iterator

    init(_ iterator: EventStream<CommunicationState>.Iterator) {
        self.iterator = iterator
    }
}

private func nextAdvertise(
    _ iterator: inout EventStream<AdvertiseEventSnapshot>.Iterator,
    timeout: Duration
) async throws -> AdvertiseEventSnapshot {
    let box = AdvertiseIteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: AdvertiseEventSnapshot.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw TimeoutGivingUp()
            }
            return value
        }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw TimeoutGivingUp()
        }
        guard let value = try await group.next() else {
            throw TimeoutGivingUp()
        }
        group.cancelAll()
        return value
    }
}

private final class AdvertiseIteratorBox: @unchecked Sendable {
    var iterator: EventStream<AdvertiseEventSnapshot>.Iterator

    init(_ iterator: EventStream<AdvertiseEventSnapshot>.Iterator) {
        self.iterator = iterator
    }
}

private final class ResponseIteratorBox: @unchecked Sendable {
    var iterator: EventStream<ResponseEventSnapshot>.Iterator

    init(_ iterator: EventStream<ResponseEventSnapshot>.Iterator) {
        self.iterator = iterator
    }
}

private func nextResponse(
    _ iterator: inout EventStream<ResponseEventSnapshot>.Iterator,
    timeout: Duration
) async throws -> ResponseEventSnapshot {
    let box = ResponseIteratorBox(iterator)
    defer { iterator = box.iterator }

    return try await withThrowingTaskGroup(of: ResponseEventSnapshot.self) { group in
        group.addTask {
            guard let value = await box.iterator.next() else {
                throw TimeoutGivingUp()
            }
            return value
        }
        group.addTask {
            try await _Concurrency.Task.sleep(for: timeout)
            throw TimeoutGivingUp()
        }
        guard let value = try await group.next() else {
            throw TimeoutGivingUp()
        }
        group.cancelAll()
        return value
    }
}
