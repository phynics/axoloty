// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Foundation
import Observation
@testable import Axoloty

@Suite
struct ObservationLinuxTests {

    @Test
    func testObservationModuleImportsOnLinux() {
        // Verify the Observation framework is available in the Linux Swift 6.3
        // container. This is a prerequisite gate before later tickets use
        // Observation-based local state.
        #expect(true, "Observation module imported successfully")
    }

    @Test
    func testWithObservationTrackingAvailable() async {
        // Verify withObservationTracking is callable. On Linux Swift 6.3,
        // the @Observable macro has known limitations with the Observable
        // protocol synthesis. This test validates the tracking API itself.
        var trackingFired = false

        withObservationTracking {
            trackingFired = true
        } onChange: {
            // no-op
        }

        // The initial application block runs synchronously.
        #expect(trackingFired)
    }

    @Test
    func testEventHubWithStateStreamOnLinux() async {
        // Verify EventHub state streams work correctly on Linux.
        let hub = EventHub()
        let stream: EventStream<Double> = await hub.registerStream(
            key: "sensor-state",
            buffering: .state,
            onFirst: {},
            onLast: {}
        )

        await hub.yield(value: 23.5, to: "sensor-state")

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.finish(key: "sensor-state")

        var values: [Double] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [23.5])
    }

    @Test
    func testEventHubWithEventStreamOnLinux() async {
        // Verify EventHub event streams work correctly on Linux.
        let hub = EventHub()
        let stream: EventStream<String> = await hub.registerStream(
            key: "event-test",
            buffering: .event,
            onFirst: {},
            onLast: {}
        )

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await hub.yield(value: "hello", to: "event-test")
        await hub.yield(value: "world", to: "event-test")
        await hub.finish(key: "event-test")

        var values: [String] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == ["hello", "world"])
    }
}
