// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("a stale transport frame reports its own diagnostic and does not touch the capacity signal")
    func staleTransportFrameReportsAccurateDiagnostic() async throws {
        // Queuing a frame on the transport's currently installed callback and
        // then immediately advancing the transport epoch (with no
        // intervening await) races the executor's ingress pump against
        // `reconnect()`: the pump captured the *old* epoch when it was
        // created, so if it dequeues the frame after `reconnect()` has
        // already bumped the epoch, the frame is processed as stale rather
        // than delivered. Which side of that race wins is not guaranteed by
        // the language, so retry a bounded number of times rather than
        // asserting on a single race outcome.
        var observed: RuntimeDiagnostic?
        for _ in 0..<40 where observed == nil {
            let definition = try makeDefinition()
            let transport = TestTransport()
            let runtime = AxolotyRuntime(definition: definition, transport: transport)
            try await runtime.start()

            let diagnosticsIterator = RuntimeTestDiagnosticIteratorBox((await runtime.diagnostics()).makeAsyncIterator())

            let staleTopic = "coaty/3/test/ADV:CoatyObject/33333333-3333-4333-8333-333333333333"
            let stalePayload = Array(#"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.StaleFixture","name":"stale-fixture"}}"#.utf8)
            await transport.deliver(.profile(topic: staleTopic, payload: stalePayload, nowMS: 0))
            await runtime.reconnect()

            try await waitUntil("runtime to finish reconnecting") {
                await runtime.state() == .running
            }

            let diagnostic = try? await withThrowingTaskGroup(of: RuntimeDiagnostic?.self) { group in
                group.addTask { await diagnosticsIterator.next() }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(100))
                    throw RuntimeTestTimeout.waitingForAdvertiseEvent
                }
                defer { group.cancelAll() }
                return try #require(try await group.next() ?? nil)
            }

            if let diagnostic {
                #expect(diagnostic.kind == .staleTransportFrame)
                #expect((await runtime.diagnosticsSnapshot()).ingressSaturation == 0)
                #expect((await runtime.diagnosticsSnapshot()).dispatchSaturation == 0)
                observed = diagnostic
            }
            await runtime.stop()
        }

        try #require(observed != nil, "the stale-epoch race was not reproduced across 40 attempts")
    }
}
