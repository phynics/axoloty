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

    /// Container that places the workspace at whatever offset the compiler
    /// chooses. With a byte-aligned workspace that offset is odd, which is the
    /// shape the host tokenizer traps on.
    struct MisalignedContainer: ~Copyable {
        var prefix: UInt8
        var workspace: EmbeddedWireParserWorkspace
    }

    /// The SWAR tokenizer rebinds the workspace buffer to `UInt64`, so the
    /// workspace must be eight-byte-aligned even at an odd container offset.
    @Test
    func inlineWorkspaceIsOctetAlignedAtAnOddAddress() {
        var container = MisalignedContainer(prefix: 0, workspace: EmbeddedWireParserWorkspace())
        let offset = container.workspace.withStorage { buffer in
            Int(bitPattern: buffer.baseAddress!) % MemoryLayout<UInt64>.alignment
        }
        #expect(offset == 0)
    }

    /// A long string enters the tokenizer's eight-byte scan path. Reading it
    /// through a workspace at an odd container offset must not trap.
    @Test
    func inlineWorkspaceTokenizesALongStringAtAnOddAddress() {
        var container = MisalignedContainer(prefix: 0, workspace: EmbeddedWireParserWorkspace())
        let name = String(repeating: "a", count: 300)
        let payload = Array("{\"name\":\"\(name)\"}".utf8)
        let reader = payload.withUnsafeBufferPointer { buffer in
            WireReader(
                bytes: buffer.baseAddress!, length: buffer.count, workspace: &container.workspace
            )
        }
        #expect(reader.readString("name")?.length == 300)
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
