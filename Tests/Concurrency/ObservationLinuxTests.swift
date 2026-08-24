// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
// Compile probe: Linux support is established by importing Observation while
// the real runtime fallback coverage remains in the Broadcast tests below.
import Observation
@testable import Axoloty

@Suite
struct ObservationLinuxTests {

    @Test
    func testBroadcastStateStreamOnLinux() async {
        // Verify Broadcast state streams work correctly on Linux.
        let broadcast = Broadcast<Double>(mode: .state)
        let stream = await broadcast.subscribe()

        await broadcast.send(23.5)

        var it = stream.makeAsyncIterator()
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
