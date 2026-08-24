// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyObjectModel
import AxolotyStaticRuntime
import AxolotyWire
import Testing

private struct MacroJSONValue: JSONIoValue {
    let enabled: Bool

    init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        switch value.kind {
        case .trueValue: enabled = true
        case .falseValue: enabled = false
        default: throw .invalidValue
        }
    }

    borrowing func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        if enabled { try output.write("true") }
        else { try output.write("false") }
    }
}

private struct MacroBinaryValue: BinaryIoValue {
    let byte: UInt8

    init(ioBytes: borrowing ByteSlice) throws(IoValueError) {
        guard ioBytes.length == 1, let byte = ioBytes.byte(at: 0) else {
            throw .invalidValue
        }
        self.byte = byte
    }

    borrowing func encodeIoBytes(into output: inout IoByteOutput) throws(IoValueError) {
        var byte = byte
        var failure: IoValueError?
        withUnsafePointer(to: &byte) { pointer in
            do throws(IoValueError) {
                try output.write(ByteSlice(bytes: pointer, length: 1))
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }
}

nonisolated(unsafe) private var jsonReceipt: (UInt32, Bool, UInt32, IoRouteKind)?
nonisolated(unsafe) private var binaryReceipt: (UInt32, UInt8, UInt32, IoRouteKind)?
nonisolated(unsafe) private var dynamicReceipt: (UInt32, IoValueRepresentation)?
nonisolated(unsafe) private var fixedRepresentationReceipt = false

private struct PermissiveFixedJSONValue: IoEndpointValue {
    static let fixedRepresentation: IoValueRepresentation? = .json

    static func decodeIoPayload(
        _ payload: borrowing ByteSlice,
        representation: IoValueRepresentation
    ) throws(IoValueError) -> Self {
        Self()
    }

    borrowing func withEncodedIoPayload<R>(
        representation: IoValueRepresentation,
        _ body: (borrowing ByteSlice) throws -> R
    ) throws -> R {
        try body(staticIoMacroSlice("null"))
    }
}

@StaticIoActor(MacroJSONValue.self)
private enum MacroJSONHandler {
    static func receive(
        context: UInt32,
        value: borrowing MacroJSONValue,
        delivery: borrowing IoDeliveryContext
    ) {
        jsonReceipt = (
            context,
            value.enabled,
            delivery.associationGeneration,
            delivery.routeKind
        )
    }
}

@StaticIoActor(MacroBinaryValue.self)
private enum MacroBinaryHandler {
    static func receive(
        context: UInt32,
        value: borrowing MacroBinaryValue,
        delivery: borrowing IoDeliveryContext
    ) {
        binaryReceipt = (
            context,
            value.byte,
            delivery.receivedAtMS,
            delivery.routeKind
        )
    }
}

@StaticIoActor(DynamicIoValue.self)
private enum MacroDynamicHandler {
    static func receive(
        context: UInt32,
        value: borrowing DynamicIoValue,
        delivery: borrowing IoDeliveryContext
    ) {
        dynamicReceipt = (context, value.representation)
    }
}

@StaticIoActor(PermissiveFixedJSONValue.self)
private enum PermissiveFixedJSONHandler {
    static func receive(
        context: UInt32,
        value: borrowing PermissiveFixedJSONValue,
        delivery: borrowing IoDeliveryContext
    ) {
        fixedRepresentationReceipt = true
    }
}

private func registeredEntry<Handler: StaticIoActorHandler>(
    _ type: Handler.Type
) -> StaticIoHandlerEntry {
    type.staticIoHandlerEntry
}

@Suite("Static IO actor macro", .serialized)
struct StaticIoActorMacroTests {
    @Test("heterogeneous generated handlers dispatch through generic registration")
    func heterogeneousHandlersDispatch() {
        jsonReceipt = nil
        binaryReceipt = nil
        let json = registeredEntry(MacroJSONHandler.self)
        let binary = registeredEntry(MacroBinaryHandler.self)
        json.invoke(
            context: 7,
            payload: staticIoMacroSlice("true"),
            representation: .json,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 41,
            associationGeneration: 3,
            routeKind: .coaty
        )
        binary.invoke(
            context: 9,
            payload: staticIoMacroSlice("*"),
            representation: .binary,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 42,
            associationGeneration: 4,
            routeKind: .external
        )

        #expect(jsonReceipt?.0 == 7)
        #expect(jsonReceipt?.1 == true)
        #expect(jsonReceipt?.2 == 3)
        #expect(jsonReceipt?.3 == .coaty)
        #expect(binaryReceipt?.0 == 9)
        #expect(binaryReceipt?.1 == Character("*").asciiValue)
        #expect(binaryReceipt?.2 == 42)
        #expect(binaryReceipt?.3 == .external)
        #expect(MemoryLayout<StaticIoHandlerEntry>.size == MemoryLayout<UnsafeRawPointer>.size)
    }

    @Test("dynamic generated handler enforces registration representation")
    func dynamicHandlerDispatch() {
        dynamicReceipt = nil
        let handler = registeredEntry(MacroDynamicHandler.self)
        handler.invoke(
            context: 11,
            payload: staticIoMacroSlice("x"),
            representation: .binary,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 43,
            associationGeneration: 5,
            routeKind: .external
        )
        #expect(dynamicReceipt?.0 == 11)
        #expect(dynamicReceipt?.1 == .binary)
    }

    @Test("malformed payloads never invoke generated handlers")
    func malformedPayloadDrops() {
        jsonReceipt = nil
        registeredEntry(MacroJSONHandler.self).invoke(
            context: 1,
            payload: staticIoMacroSlice("not-json"),
            representation: .json,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 0,
            associationGeneration: 0,
            routeKind: .coaty
        )
        #expect(jsonReceipt == nil)
    }

    @Test("handler entry enforces the value type's fixed representation")
    func fixedRepresentationIsEnforced() {
        fixedRepresentationReceipt = false
        registeredEntry(PermissiveFixedJSONHandler.self).invoke(
            context: 1,
            payload: staticIoMacroSlice("null"),
            representation: .binary,
            sourceID: .zero,
            actorID: .zero,
            receivedAtMS: 0,
            associationGeneration: 0,
            routeKind: .coaty
        )
        #expect(!fixedRepresentationReceipt)
    }
}

private func staticIoMacroSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}
