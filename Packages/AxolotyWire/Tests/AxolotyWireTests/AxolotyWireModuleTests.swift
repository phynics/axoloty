// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Pure wire-module regressions that cannot import the Axoloty host runtime.
@Suite
struct AxolotyWireModuleTests {
    @Test
    func publicWireTypesAreUsableWithoutHostRuntime() throws {
        let identifier = try #require(UUID16(parsing: "33333333-3333-4333-8333-333333333333"))

        #expect(identifier != .zero)
        #expect(WireEventType.advertise.rawValue == "ADV")
        #expect(WireBufferConfig.maxTopicLength == 256)
        #expect(WireBufferConfig.maxPayloadSize == 2 * 1024)

        let workspace = EmbeddedWireParserWorkspace()
        #expect(workspace.capacity == WireBufferConfig.maxPayloadSize + 8)
    }
}
