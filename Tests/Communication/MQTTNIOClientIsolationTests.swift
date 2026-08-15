// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
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
