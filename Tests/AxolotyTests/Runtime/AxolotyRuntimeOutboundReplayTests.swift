// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

/// A transport whose `perform(_:namespace:)` fails the first publish it is
/// asked to send (simulating a connection drop mid-send) and accepts every
/// publish after that.
actor FailOnceOnPublishTransport: AxolotyRuntimeTransport {
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var failure: (@Sendable (Error) -> Void)?
    private(set) var sent: [RuntimeOutboundMessage] = []
    private var shouldFailNextPublish: Bool

    init(failFirstPublish: Bool = true) {
        self.shouldFailNextPublish = failFirstPublish
    }

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        failure = handler
    }

    func perform(_ effect: RuntimeTransportEffect) async throws {
        guard case .publish(let publication) = effect else { return }
        if shouldFailNextPublish {
            shouldFailNextPublish = false
            throw TestTransportFailure()
        }
        sent.append(publication)
    }

    func stop() async { receive = nil }
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}

    func sentCount() -> Int { sent.count }
    func sentPayloads() -> [[UInt8]] { sent.map(\.payload) }
}

extension AxolotyRuntimeTests {
    @Test("a publication queued but unsent when the transport fails is replayed exactly once after reconnect")
    func queuedOutboundEffectSurvivesTransportFailureAndReplaysOnce() async throws {
        let definition = try makeDefinition()
        let transport = FailOnceOnPublishTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let payload = Array(#"{"privateData":{"replay":true}}"#.utf8)
        let receipt = await runtime.publish(.channel(identifier: "replay-publication", payload: payload))
        #expect(receipt == .accepted)

        // The outbound pump's first perform() call fails, which routes
        // through transportFailed(_:) and moves the runtime to reconnecting.
        try await waitUntil("runtime to enter reconnecting state after a failed send") {
            await runtime.state() == .reconnecting
        }
        #expect(await runtime.state() == .reconnecting)
        #expect(await transport.sentCount() == 0)

        await runtime.reconnect()
        try await waitUntil("the queued publication to reach the transport exactly once") {
            await transport.sentCount() == 1
        }
        #expect(await runtime.state() == .running)
        #expect(await transport.sentCount() == 1)
        #expect(await transport.sentPayloads() == [payload])

        // Give any spurious duplicate delivery a chance to arrive before
        // asserting it never does.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sentCount() == 1)

        await runtime.stop()
    }
}
