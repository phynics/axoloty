// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
@preconcurrency import MQTTNIO
import Foundation
import NIO
import Testing

@Suite
struct BroadcastTransportTestsMQTTNIOIsolation {
    @Test
    func connectAndDisconnectAreSafeAcrossCallbackContexts() async throws {
        let client = try makeClient()
        let box = ClientBox(client)

        try await race("connect and disconnect") {
            box.client.connect(lastWillTopic: "test", lastWillMessage: "message")
        } second: {
            box.client.disconnect()
        }
    }

    @Test
    func inboundStateDeliveryDoesNotRaceStreamSetup() async throws {
        let client = try makeClient()
        let box = ClientBox(client)

        try await race("inbound state delivery and stream setup") {
            box.client.updateCommunicationState(.online)
        } second: {
            box.client.setStreams(makeTestStreams())
        }
    }

    @Test
    func streamSetupCanRepeatWhilePublishing() async throws {
        let client = try makeClient()
        let box = ClientBox(client)

        try await race("stream setup and publishing") {
                for _ in 0 ..< 10 {
                    box.client.setStreams(makeTestStreams())
                }
        } second: {
                for _ in 0 ..< 10 {
                    box.client.publish("test/topic", message: "message")
                }
        }
    }

    @Test
    func bytePublishCanOverlapTeardown() async throws {
        let client = try makeClient()
        let box = ClientBox(client)

        try await race("byte publishing and teardown") {
                for _ in 0 ..< 10 {
                    box.client.publish("test/topic", message: [1, 2, 3])
                }
        } second: {
            box.client.disconnect()
        }
    }

    @Test
    func delegateReplacementIsSynchronizedWithInboundState() async throws {
        let client = try makeClient()
        let box = ClientBox(client)
        let delegate = IsolationDelegate()

        try await race("delegate replacement and inbound state") {
            box.client.delegate = delegate
        } second: {
            box.client.updateCommunicationState(.offline)
        }
    }

    @Test
    func teardownCanRaceReconnectCancellation() async throws {
        let client = try makeClient()
        let box = ClientBox(client)

        try await race("teardown and reconnect cancellation") {
            box.client.connect(lastWillTopic: "test", lastWillMessage: "message")
        } second: {
            box.client.disconnect()
        }
    }

    @Test
    func stopDuringConnectionSetupLetsLaterStartReachOnline() async throws {
        let recorder = ConnectStateRecorder()
        let spool = ConnectFutureSpool()
        let client = try makeSeamClient(delegate: recorder, spool: spool)

        // 1. Start: a connection attempt is issued and left unresolved, as when a
        //    broker delays connection completion.
        client.connect(lastWillTopic: "test", lastWillMessage: "message")
        let lateAttempt = try #require(spool.takeNextPromise())

        // 2. Stop before the attempt completes.
        client.disconnect()

        // 3. Allow the old attempt to complete late: it must NOT transition the
        //    stopped client online, and the completed-but-retired socket must not
        //    leave `isIntentionalDisconnect` set in a way that blocks a restart.
        lateAttempt.succeed(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!recorder.states.contains(.online), "late connect result after stop must not go online")

        // 4. A later start connects normally and reaches online, without waiting
        //    for an external close of the retired late socket.
        client.connect(lastWillTopic: "test", lastWillMessage: "message")
        let restartAttempt = try #require(spool.takeNextPromise())
        restartAttempt.succeed(true)
        try await waitUntilOnline(recorder)
    }
}

/// Records `CommunicationState` callbacks so a test can assert than a retired
/// late connect never transitions the client online, and that a later start does.
private final class ConnectStateRecorder: CommunicationClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [CommunicationState] = []

    var states: [CommunicationState] {
        lock.lock()
        defer { lock.unlock() }
        return _states
    }

    func didReceiveStart() {}

    func didUpdateCommunicationState(_ state: CommunicationState) {
        lock.lock()
        _states.append(state)
        lock.unlock()
    }
}

/// Supplies on-demand connection futures for the `ConnectHandler` seam so a
/// connect-stop-start race can be driven deterministically without a live broker.
private final class ConnectFutureSpool: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [EventLoopPromise<Bool>] = []

    /// Returns a new on-demand connection future for `client` and records it so
    /// the test can complete it later.
    func makeFuture(for client: MQTTClient) -> EventLoopFuture<Bool> {
        let promise = client.eventLoopGroup.next().makePromise(of: Bool.self)
        lock.lock()
        pending.append(promise)
        lock.unlock()
        return promise.futureResult
    }

    func takeNextPromise() -> EventLoopPromise<Bool>? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

private func makeSeamClient(
    delegate: CommunicationClientDelegate,
    spool: ConnectFutureSpool
) throws -> MQTTNIOClient {
    let options = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: true
    )
    options.clientId = "connect-seam-test"
    let client = try MQTTNIOClient(
        mqttClientOptions: options,
        delegate: delegate,
        publishHandler: nil,
        connectHandler: { spool.makeFuture(for: $0) }
    )
    client.setStreams(makeTestStreams())
    return client
}

private func waitUntilOnline(_ recorder: ConnectStateRecorder) async throws {
    for _ in 0..<200 {
        if recorder.states.contains(.online) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("later start did not reach online before timeout")
}

private final class ClientBox: @unchecked Sendable {
    let client: MQTTNIOClient

    init(_ client: MQTTNIOClient) {
        self.client = client
    }
}

/// Releases both operations only after each has reached the same start point.
/// This makes the contested transport transition deterministic under TSan.
private actor RaceStartGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard arrivals < 2 else {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }
}

private func race(
    _ description: String,
    first: @escaping @Sendable () -> Void,
    second: @escaping @Sendable () -> Void
) async throws {
    let gate = RaceStartGate()
    try await withTimeout(description, timeout: .seconds(2)) {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await gate.wait()
                first()
            }
            group.addTask {
                await gate.wait()
                second()
            }
        }
    }
}

private final class IsolationDelegate: CommunicationClientDelegate, @unchecked Sendable {
    func didReceiveStart() {}
}

private func makeClient() throws -> MQTTNIOClient {
    let options = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: false
    )
    options.clientId = "isolation-test"
    let client = try MQTTNIOClient(mqttClientOptions: options, delegate: IsolationDelegate())
    client.setStreams(makeTestStreams())
    return client
}

private func makeTestStreams() -> CommunicationStreams {
    CommunicationStreams(
        communicationState: Broadcast(mode: .state),
        operatingState: Broadcast(mode: .state),
        rawMQTTMessages: Broadcast(mode: .event),
        parsedMQTTMessages: Broadcast(mode: .event),
        ioValues: Broadcast(mode: .event),
        ioValueFamily: BroadcastFamily(mode: .event),
        ioStateFamily: BroadcastFamily(mode: .state),
        associateFamily: BroadcastFamily(mode: .event),
        advertiseFamily: BroadcastFamily(mode: .event),
        advertiseAll: Broadcast(mode: .event),
        deadvertise: Broadcast(mode: .event),
        discover: Broadcast(mode: .event),
        query: Broadcast(mode: .event),
        callFamily: BroadcastFamily(mode: .event),
        updateFamily: BroadcastFamily(mode: .event),
        channelFamily: BroadcastFamily(mode: .event),
        responseFamily: BroadcastFamily(mode: .event)
    )
}
