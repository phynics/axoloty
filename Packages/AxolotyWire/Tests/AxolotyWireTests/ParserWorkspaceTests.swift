// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

@Suite
struct ParserWorkspaceTests {
    @Test
    func inlineAndHostWorkspacesUseTheSameReaderAlgorithm() {
        let payload = Array(#"{"ok":true,"value":7}"#.utf8)
        var inline = EmbeddedWireParserWorkspace()
        var host = HostWireParserWorkspace(capacity: 4096)

        let inlineReader = payload.withUnsafeBufferPointer { buffer in
            WireReader(
                bytes: buffer.baseAddress!, length: buffer.count, workspace: &inline
            )
        }
        let hostReader = payload.withUnsafeBufferPointer { buffer in
            WireReader(
                bytes: buffer.baseAddress!, length: buffer.count, workspace: &host
            )
        }

        #expect(inlineReader.readBool("ok") == true)
        #expect(hostReader.readBool("ok") == true)
        #expect(inlineReader.readInt("value") == hostReader.readInt("value"))
    }

    @Test
    func undersizedWorkspaceFailsWithoutChangingPayloadLimit() {
        let payload = Array(#"{"ok":true}"#.utf8)
        var workspace = InlineWireParserWorkspace<519>()
        let reader = payload.withUnsafeBufferPointer { buffer in
            WireReader(
                bytes: buffer.baseAddress!, length: buffer.count, workspace: &workspace
            )
        }

        do {
            try reader.validate()
            Issue.record("Expected the undersized workspace to be rejected")
        } catch let error {
            guard case .workspaceExceedsLimit = error.reason else {
                Issue.record("Unexpected error reason: \(error)")
                return
            }
        }
    }
}
