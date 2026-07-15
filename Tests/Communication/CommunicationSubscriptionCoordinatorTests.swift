// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

/// Tests the lifecycle of ``CommunicationSubscriptionCoordinator`` and verifies
/// that it emits subscribe and unsubscribe commands with exact counts.
@Suite
struct CommunicationSubscriptionCoordinatorTests {

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
