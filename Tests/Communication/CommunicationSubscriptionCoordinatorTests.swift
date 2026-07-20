// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

/// Tests the lifecycle of ``CommunicationSubscriptionCoordinator`` and verifies
/// that it emits subscribe and unsubscribe commands with exact counts.
@Suite
struct CommunicationSubscriptionCoordinatorTests {

    @Test
    func dispatcherForwardsCommandsInOrder() async throws {
        let client = RecordingCommunicationClient()
        let dispatcher = CommunicationSubscriptionCommandDispatcher(client: client)

        try await dispatcher.deliver(.subscribe("first"))
        try await dispatcher.deliver(.unsubscribe("first"))

        #expect(client.commands == [.subscribe("first"), .unsubscribe("first")])
    }

    @Test
    func dispatcherWaitsForSubscriptionAcknowledgement() async {
        let gate = SubscriptionGate()
        let completed = CompletionFlag()
        let client = RecordingCommunicationClient(gate: gate)
        let dispatcher = CommunicationSubscriptionCommandDispatcher(client: client)

        let delivery = _Concurrency.Task {
            try? await dispatcher.deliver(.subscribe("first"))
            await completed.mark()
        }

        await gate.waitUntilStarted()
        await _Concurrency.Task.yield()
        #expect(await completed.value == false)

        await gate.open()
        await delivery.value
        #expect(await completed.value)
    }

    @Test
    func firstAcquireOnlineEmitsOneSubscribe() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")

        #expect(await log.commands == [.subscribe("t1")])
    }

    @Test
    func duplicateAcquireOnlineEmitsOneSubscribe() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t1")

        #expect(await log.commands == [.subscribe("t1")])
    }

    @Test
    func releaseOnlineAfterSingleAcquireEmitsOneUnsubscribe() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await log.clear()
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [.unsubscribe("t1")])
    }

    @Test
    func releaseOnlineAfterMultipleAcquiresDoesNotUnsubscribeUntilFinal() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t1")
        await log.clear()
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [])
        await coordinator.release(topic: "t1")
        #expect(await log.commands == [.unsubscribe("t1")])
    }

    @Test
    func reacquireAfterReleaseSubscribesAgain() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.release(topic: "t1")
        await coordinator.acquire(topic: "t1")

        #expect(await log.commands == [.subscribe("t1"), .unsubscribe("t1"), .subscribe("t1")])
    }

    @Test
    func acquireOfflineRecordsWithoutEmitting() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.acquire(topic: "t1")

        #expect(await log.commands == [])
    }

    @Test
    func transitionOfflineToOnlineResubscribesDesiredTopicsOnce() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t2")
        await coordinator.setOnline(true)

        #expect(await log.commands == [.subscribe("t1"), .subscribe("t2")])
    }

    @Test
    func transitionOnlineToOfflineRetainsDesiredAndEmitsNoUnsubscribe() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await log.clear()
        await coordinator.setOnline(false)

        #expect(await log.commands == [])
        await coordinator.setOnline(true)
        #expect(await log.commands == [.subscribe("t1")])
    }

    @Test
    func acquireAfterOfflineTransitionDoesNotEmitUntilOnlineAgain() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.setOnline(false)
        await log.clear()
        await coordinator.acquire(topic: "t2")
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [])
        await coordinator.setOnline(true)
        #expect(await log.commands == [.subscribe("t2")])
    }

    @Test
    func releaseWhileOfflineReducesCountWithoutUnsubscribe() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t1")
        await coordinator.setOnline(true)
        await log.clear()
        await coordinator.setOnline(false)
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [])
        await coordinator.setOnline(true)
        #expect(await log.commands == [.subscribe("t1")])
    }

    @Test
    func resetOnlineEmitsUnsubscribeForAllActiveAndClearsDesired() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t2")
        await log.clear()
        await coordinator.reset()

        #expect(await log.commands == [.unsubscribe("t1"), .unsubscribe("t2")])
        await coordinator.setOnline(true)
        #expect(await log.commands == [.unsubscribe("t1"), .unsubscribe("t2")])
    }

    @Test
    func resetOfflineClearsDesiredWithoutEmitting() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.acquire(topic: "t1")
        await coordinator.setOnline(false)
        await coordinator.reset()
        await coordinator.setOnline(true)

        #expect(await log.commands == [])
    }

    @Test
    func duplicateOnlineTransitionDoesNotReemit() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await log.clear()
        await coordinator.setOnline(true)

        #expect(await log.commands == [])
    }

    @Test
    func releaseUnknownTopicIsIgnored() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [])
    }

    @Test
    func multipleTopicsHaveIndependentReferenceCounts() async {
        let log = CommandLog()
        let coordinator = CommunicationSubscriptionCoordinator(commandSink: { await log.append($0) })

        await coordinator.setOnline(true)
        await coordinator.acquire(topic: "t1")
        await coordinator.acquire(topic: "t2")
        await coordinator.release(topic: "t1")

        #expect(await log.commands == [.subscribe("t1"), .subscribe("t2"), .unsubscribe("t1")])
    }
}

private actor CommandLog {
    private(set) var commands: [SubscriptionCommand] = []

    func append(_ command: SubscriptionCommand) {
        commands.append(command)
    }

    func clear() {
        commands.removeAll()
    }
}

private final class RecordingCommunicationClient: CommunicationClient, @unchecked Sendable {
    var streams: CommunicationStreams!
    func setStreams(_ streams: CommunicationStreams) { self.streams = streams }
    var delegate: CommunicationClientDelegate = RecordingStartable()
    private let gate: SubscriptionGate?
    private(set) var commands: [SubscriptionCommand] = []

    init(gate: SubscriptionGate? = nil) {
        self.gate = gate
    }

    func connect(lastWillTopic: String, lastWillMessage: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}

    func subscribe(_ topic: String) async throws {
        commands.append(.subscribe(topic))
        if let gate {
            await gate.markStarted()
            await gate.waitUntilOpen()
        }
    }

    func unsubscribe(_ topic: String) async throws {
        commands.append(.unsubscribe(topic))
    }
}

private actor SubscriptionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilOpen() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func open() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}

private struct RecordingStartable: CommunicationClientDelegate {
    func didReceiveStart() {}
}
