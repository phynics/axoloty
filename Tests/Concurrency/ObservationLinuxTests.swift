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
        // the @Observable macro is unavailable: it expands to code referencing
        // Observation.ObservationRegistrar, which does not exist in the Linux
        // toolchain's Observation module. Direction C's @Observable state-stream
        // design is therefore blocked on Linux; all streams use Broadcast instead.
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
    func testBroadcastStateStreamOnLinux() async {
        // Verify Broadcast state streams work correctly on Linux.
        let broadcast = Broadcast<Double>(mode: .state)
        let stream = await broadcast.subscribe()

        await broadcast.send(23.5)

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.finish()

        var values: [Double] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == [23.5])
    }

    @Test
    func testBroadcastEventStreamOnLinux() async {
        // Verify Broadcast event streams work correctly on Linux.
        let broadcast = Broadcast<String>(mode: .event)
        let stream = await broadcast.subscribe()

        var it = stream.makeAsyncIterator()
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))

        await broadcast.send("hello")
        await broadcast.send("world")
        await broadcast.finish()

        var values: [String] = []
        while let v = await it.next() {
            values.append(v)
        }

        #expect(values == ["hello", "world"])
    }
}
