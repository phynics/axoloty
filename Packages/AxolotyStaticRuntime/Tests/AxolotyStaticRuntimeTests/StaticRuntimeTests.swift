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
            if case .publish = action { drained += 1 }
        }
        #expect(count == 1)
        #expect(drained == 1)
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.pendingCorrelations == 1)
    }

    @Test("wire publication variants produce one semantic delivery")
    func advertiseVariantsHaveOneSemanticDelivery() throws {
        let payload: StaticString = #"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","name":"wire-fixture"}}"#
        let operation = try ProtocolLocalOperation(
            capability: .advertise,
            sourceID: .zero,
            payload: staticPayload(payload)
        )
        var runtime = AxolotyStaticRuntime()
        #expect(runtime.send(operation) == .accepted)
        #expect(runtime.actionCount == 2)
        var publications = 0
        var semanticDeliveries = 0
        #expect(runtime.drain { action in
            guard case .publish(let publication) = action else { return }
            publications += 1
            semanticDeliveries += publication.isApplicationDelivery ? 1 : 0
        } == 2)
        #expect(publications == 2)
        #expect(semanticDeliveries == 1)
    }

    @Test("Channel identifiers are mandatory at the shared boundary")
    func channelRejectsMissingIdentifier() {
        #expect(throws: ProtocolError.self) {
            _ = try ProtocolLocalOperation(
                capability: .channel,
                sourceID: .zero,
                payload: staticPayload()
            )
        }
    }

    @Test("static outbound Channel preserves one validated identifier")
    func channelUsesValidatedIdentifier() throws {
        let identifier: StaticString = "wire-fixture-channel"
        let identifierSlice = staticPayload(identifier)
        let operation = try ProtocolLocalOperation(
            capability: .channel,
            sourceID: .zero,
            payload: staticPayload(#"{"privateData":{"sequence":7}}"#),
            operationName: identifierSlice
        )
        var runtime = AxolotyStaticRuntime()
        #expect(runtime.send(operation) == .accepted)
        var copiedFilter: [UInt8]?
        var copiedKind: ProtocolEventTypeFilterKind?
        _ = runtime.drain { action in
            guard case .publish(let publication) = action.owned(),
                  case .profile(let filter, let kind) = publication.target else { return }
            copiedFilter = filter
            copiedKind = kind
        }
        #expect(copiedFilter == Array("wire-fixture-channel".utf8))
        #expect(copiedKind == .direct)
    }

    @Test("shared Channel boundary rejects invalid topic levels", arguments: [
        "", "bad/channel", "bad#channel", "bad+channel", "bad\0channel",
        String(repeating: "a", count: 129)
    ])
    func channelRejectsInvalidIdentifier(_ identifier: String) {
        var storage = Array(identifier.utf8)
        let length = storage.count
        storage.append(0x41)
        _ = storage.withUnsafeBufferPointer { buffer in
            #expect(throws: ProtocolError.self) {
                _ = try ProtocolLocalOperation(
                    capability: .channel,
                    sourceID: .zero,
                    payload: staticPayload(),
                    operationName: ByteSlice(bytes: buffer.baseAddress!, length: length)
                )
            }
        }
    }

    @Test("shared Call boundary rejects an invalid optional operation filter")
    func callRejectsInvalidOperationFilter() throws {
        let invalid: StaticString = "bad/operation"
        let invalidSlice = staticPayload(invalid)
        #expect(throws: ProtocolError.self) {
            _ = try ProtocolLocalOperation(
                capability: .call,
                sourceID: .zero,
                correlationID: .zero,
                payload: staticPayload(),
                operationName: invalidSlice
            )
        }

        let direct = ProtocolLocalOperation.call(
            sourceID: .zero,
            correlationID: .zero,
            payload: staticPayload(),
            requestTimeoutMS: 100,
            operationName: invalidSlice
        )
        var runtime = AxolotyStaticRuntime()
        #expect(runtime.send(direct) == .rejected(.malformedFrame))
        #expect(runtime.actionCount == 0)
        #expect(runtime.state.pendingCorrelations == 0)
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
