// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyStaticRuntime
import AxolotyProtocol
import AxolotyWire

private func staticPayload(_ value: StaticString = "{}") -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

@Suite("Axoloty static runtime")
struct StaticRuntimeTests {
    @Test("one shared fixed processor sends and drains synchronously")
    func sendAndDrain() throws {
        let source = UUID16.zero
        let operation = try ProtocolLocalOperation(
            capability: .discover,
            sourceID: source,
            correlationID: source,
            payload: staticPayload(),
            requestTimeoutMS: 100
        )
        var runtime = AxolotyStaticRuntime()
        #expect(runtime.send(operation, nowMS: 10) == .accepted)
        #expect(runtime.actionCount == 1)
        var drained = 0
        let count = runtime.drain { action in
            drained += action.kind == .publish ? 1 : 0
        }
        #expect(count == 1)
        #expect(drained == 1)
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.pendingCorrelations == 1)
    }

    @Test("cancel and reset clear pending transport state")
    func cancelAndReset() throws {
        let source = UUID16.zero
        let operation = try ProtocolLocalOperation(
            capability: .call,
            sourceID: source,
            correlationID: source,
            payload: staticPayload(),
            requestTimeoutMS: 100
        )
        var runtime = AxolotyStaticRuntime()
        #expect(runtime.send(operation, nowMS: 10) == .accepted)
        let cancelled = runtime.cancel(correlationID: source)
        #expect(cancelled)
        #expect(runtime.state.pendingCorrelations == 0)
        runtime.resetTransport()
        #expect(runtime.state.activeRecords == 0)
        #expect(runtime.state.pendingCorrelations == 0)
    }
}
