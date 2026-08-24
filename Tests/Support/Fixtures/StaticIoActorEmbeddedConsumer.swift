// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

struct EmbeddedProbeValue: BinaryIoValue {
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
        withUnsafeBytes(of: &byte) { buffer in
            do throws(IoValueError) {
                try output.write(ByteSlice(
                    bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    length: buffer.count
                ))
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }
}

@StaticIoActor(EmbeddedProbeValue.self)
enum EmbeddedProbeActor {
    static func receive(
        context: UInt32,
        value: borrowing EmbeddedProbeValue,
        delivery: borrowing IoDeliveryContext
    ) {
        _ = context
        _ = value.byte
        _ = delivery.associationGeneration
    }
}

func embeddedMacroEntry() -> StaticIoHandlerEntry {
    EmbeddedProbeActor.staticIoHandlerEntry
}
