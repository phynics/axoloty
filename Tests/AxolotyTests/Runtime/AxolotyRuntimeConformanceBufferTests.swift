// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@_spi(AxolotyRuntimeAdapter) @testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("conformance action buffer stays bounded under sustained dispatch with no conformance drain")
    func conformanceActionBufferStaysBoundedWithoutDrain() async throws {
        // A tiny dispatch capacity makes the bound trivial to exceed with a
        // handful of iterations, while staying well under the portable
        // processor's own active-object ceiling so every delivery below is
        // accepted rather than rejected as duplicate/over capacity there.
        let dispatchCapacity = 4
        let definition = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: try RuntimeCapacities(dispatch: dispatchCapacity)
        ).finish()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        // Each iteration advertises a distinct source/object pair so the
        // portable processor's bounded active-object tracking treats every
        // delivery as new work rather than a duplicate of the last one.
        let iterations = 60
        for index in 0..<iterations {
            let topic = "coaty/3/test/ADV:CoatyObject/00000000-0000-4000-8000-\(String(format: "%012x", index))"
            let payload = Array(
                #"{"object":{"objectId":"11111111-1111-4111-8111-\#(String(format: "%012x", index))","coreType":"CoatyObject","objectType":"com.coaty.test.ConformanceBufferFixture","name":"conformance-buffer-fixture"}}"#.utf8
            )
            let receipt = await runtime.receive(.profile(route: topic, payload: payload, nowMS: 0))
            #expect(receipt == .accepted)
        }

        // No call to `conformanceObservation()` occurred above, so nothing has
        // ever drained the buffer. Sustained dispatch traffic well beyond the
        // dispatch capacity must not have grown it past that bound.
        let observation = await runtime.conformanceObservation()
        #expect(observation.actions.count <= dispatchCapacity)
        #expect(observation.actions.count < iterations)

        await runtime.stop()
    }
}
