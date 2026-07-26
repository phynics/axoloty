// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@Suite
struct BroadcastTransportTestsMQTTNIOIsolation {
    @Test
    func connectAndDisconnectAreSafeAcrossCallbackContexts() async {
        let client = makeClient()
        let box = ClientBox(client)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { box.client.connect(lastWillTopic: "test", lastWillMessage: "message") }
            group.addTask { box.client.disconnect() }
        }
    }

    @Test
    func inboundStateDeliveryDoesNotRaceStreamSetup() async {
        let client = makeClient()
        let box = ClientBox(client)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { box.client.updateCommunicationState(.online) }
            group.addTask { box.client.setStreams(makeTestStreams()) }
        }
    }

    @Test
    func streamSetupCanRepeatWhilePublishing() async {
        let client = makeClient()
        let box = ClientBox(client)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0 ..< 10 {
                    box.client.setStreams(makeTestStreams())
                }
            }
            group.addTask {
                for _ in 0 ..< 10 {
                    box.client.publish("test/topic", message: "message")
                }
            }
        }
    }

    @Test
    func bytePublishCanOverlapTeardown() async {
        let client = makeClient()
        let box = ClientBox(client)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0 ..< 10 {
                    box.client.publish("test/topic", message: [1, 2, 3])
                }
            }
            group.addTask { box.client.disconnect() }
        }
    }

    @Test
    func delegateReplacementIsSynchronizedWithInboundState() async {
        let client = makeClient()
        let box = ClientBox(client)
        let delegate = IsolationDelegate()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { box.client.delegate = delegate }
            group.addTask { box.client.updateCommunicationState(.offline) }
        }
    }

    @Test
    func teardownCanRaceReconnectCancellation() async {
        let client = makeClient()
        let box = ClientBox(client)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { box.client.connect(lastWillTopic: "test", lastWillMessage: "message") }
            group.addTask {
                await _Concurrency.Task.yield()
                box.client.disconnect()
            }
        }
    }
}

private final class ClientBox: @unchecked Sendable {
    let client: MQTTNIOClient

    init(_ client: MQTTNIOClient) {
        self.client = client
    }
}

private final class IsolationDelegate: CommunicationClientDelegate, @unchecked Sendable {
    func didReceiveStart() {}
}

private func makeClient() -> MQTTNIOClient {
    let options = MQTTClientOptions(
        host: "127.0.0.1",
        port: 1883,
        shouldTryMDNSDiscovery: false,
        autoReconnect: false
    )
    options.clientId = "isolation-test"
    let client = MQTTNIOClient(mqttClientOptions: options, delegate: IsolationDelegate())
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
        deadvertise: Broadcast(mode: .event),
        discover: Broadcast(mode: .event),
        query: Broadcast(mode: .event),
        callFamily: BroadcastFamily(mode: .event),
        updateFamily: BroadcastFamily(mode: .event),
        channelFamily: BroadcastFamily(mode: .event),
        responseFamily: BroadcastFamily(mode: .event)
    )
}
