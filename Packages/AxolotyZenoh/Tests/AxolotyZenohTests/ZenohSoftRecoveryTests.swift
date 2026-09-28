// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Foundation

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotyZenoh

@Suite("Zenoh soft recovery")
struct ZenohSoftRecoveryTests {
    private static let namespace = "soft-node"
    private static let actorID = "00000000-0000-4000-8000-000000000a02"
    private static let remoteSourceID = "00000000-0000-4000-8000-000000000a01"

    @Test("soft recovery releases active exact external routes without exhausting the route table")
    func softRecoveryReleasesExternalRoutes() async throws {
        let session = RecordingZenohSession()
        let now = NanosecondTestClock()
        let configuration = try ZenohBindingConfiguration()
        let binding = ZenohBinding(
            configuration: configuration,
            session: session,
            clock: { 0 },
            receivePumpIntervalNanoseconds: 60_000_000_000,
            monotonicNowNanoseconds: { now.value },
            routerLossDebounceNanoseconds: 1_000
        )
        let runtime = AxolotyRuntime(definition: try Self.makeDefinition(), transport: binding)
        try await runtime.start()
        session.connectedRouters = 1
        _ = binding.drainReceiveQueues()

        // More recoveries than route slots: a leaked subscription per episode
        // would exhaust `maximumExternalRoutes` before the loop finishes.
        let cycles = configuration.maximumExternalRoutes + 2
        for cycle in 0..<cycles {
            let route = "legacy/soft-recovery/\(cycle)"
            session.enqueuePublication(
                route: "coaty/3/\(Self.namespace)/ASC/\(Self.remoteSourceID)",
                payload: Array(#"{"ioSourceId":"\#(Self.remoteSourceID)","ioActorId":"\#(Self.actorID)","associatingRoute":"\#(route)"}"#.utf8)
            )
            _ = binding.drainReceiveQueues()
            try await Self.waitUntil("external route \(cycle) to be subscribed") {
                session.withOperations { Self.liveExternalSubscriptions(in: $0) } == [route]
            }
            #expect(await runtime.diagnosticsSnapshot().activeExternalSubscriptions == 1)

            // Router loss beyond the debounce, then recovery on the same session.
            session.connectedRouters = 0
            _ = binding.drainReceiveQueues()
            now.advance(by: 1_000)
            _ = binding.drainReceiveQueues()
            try await Self.waitUntil("runtime to enter reconnecting state") {
                await runtime.state() == .reconnecting
            }
            session.connectedRouters = 1
            _ = binding.drainReceiveQueues()
            try await Self.waitUntil("soft recovery to resume the runtime") {
                await runtime.state() == .running
            }
            #expect(session.withOperations { Self.liveExternalSubscriptions(in: $0) }.isEmpty)
            #expect(await runtime.diagnosticsSnapshot().activeExternalSubscriptions == 0)
        }

        // Soft recovery never tears the session down.
        #expect(session.withOperations { $0.filter { $0 == .close }.count } == 0)
        await runtime.stop()
    }

    private static func makeDefinition() throws -> RuntimeDefinition {
        let identity = try RuntimeIdentity(id: .zero, name: "soft-recovery")
        var builder = try RuntimeBuilder(identity: identity, namespace: namespace)
        let actorJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000a02\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
        _ = try builder.ioActor(
            metadata: try Object<IoActorMetadata>(decoding: ByteSlice(
                bytes: actorJSON.utf8Start,
                length: actorJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        ) { _, _ in }
        return try builder.finish()
    }

    /// Returns external routes subscribed and not yet unsubscribed.
    private static func liveExternalSubscriptions(in operations: [RecordingZenohSession.Operation]) -> [String] {
        var live: [Int: String] = [:]
        for operation in operations {
            switch operation {
            case let .subscribe(route, id):
                let text = String(decoding: route, as: UTF8.self)
                if !text.hasPrefix("coaty/") { live[id] = text }
            case let .unsubscribe(id):
                live[id] = nil
            default:
                break
            }
        }
        return live.sorted { $0.key < $1.key }.map(\.value)
    }

    private static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(description)")
        throw CancellationError()
    }
}
