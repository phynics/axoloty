// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Public Axoloty/1 consumer compiled with the complete portable Core graph and
// no `_JSONCore` module. This exercises bounded object materialization and the
// shared static protocol processor through its selected CBOR codec.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

@main
struct EmbeddedCBORCoreConsumerProbe {
    static func main() {
        let objectBytes: [UInt8] = [
            0xA1, 0x64, 0x6E, 0x61, 0x6D, 0x65, 0x63, 0x63, 0x61, 0x74,
        ]
        let objectStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: objectBytes.count)
        objectStorage.initialize(from: objectBytes, count: objectBytes.count)
        defer {
            objectStorage.deinitialize(count: objectBytes.count)
            objectStorage.deallocate()
        }
        let object = try! BoundedCBORObject<64, 4>(decoding: ByteSlice(
            bytes: UnsafePointer(objectStorage),
            length: objectBytes.count
        ))
        precondition(object.count == 1)
        var name: [UInt8] = []
        precondition(object.withValue(for: "name") { name = $0.ownedBytes() })
        precondition(name == [0x63, 0x63, 0x61, 0x74])

        let idText: StaticString = "00000000-0000-4000-8000-000000000001"
        let idBytes = ByteSlice(bytes: idText.utf8Start, length: idText.utf8CodeUnitCount)
        let source = UUID16(parsing: idBytes)!
        let operationPayload: [UInt8] = [
            0xA1, 0x66, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74,
            0xA4,
            0x64, 0x6E, 0x61, 0x6D, 0x65, 0x63, 0x6E,
            0x68, 0x63, 0x6F, 0x72, 0x65, 0x54, 0x79, 0x70, 0x65, 0x6B,
            0x43, 0x6F, 0x61, 0x74, 0x79, 0x4F, 0x62, 0x6A, 0x65, 0x63, 0x74,
            0x68, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74, 0x49, 0x64,
            0xD8, 0x25, 0x50,
            0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11,
            0x81, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
            0x6A, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74, 0x54, 0x79, 0x70, 0x65,
            0x78, 0x1B,
            0x63, 0x6F, 0x6D, 0x2E, 0x63, 0x6F, 0x61, 0x74, 0x79, 0x2E,
            0x74, 0x65, 0x73, 0x74, 0x2E, 0x57, 0x69, 0x72, 0x65, 0x46, 0x69,
            0x78, 0x74, 0x75, 0x72, 0x65,
        ]
        var runtime = try! StaticRuntime<2, 256>(
            registryID: ObjectID(uuid: source),
            wireCodec: WireCodec(profile: .axoloty1CBOR)
        )
        let result = operationPayload.withUnsafeBufferPointer { buffer in
            let operation = try! ProtocolLocalOperation(
                capability: .advertise,
                sourceID: source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            return runtime.send(operation)
        }
        precondition(result == .accepted)
        precondition(runtime.state.activeObjects == 1)
        precondition(runtime.actionCount == 2)
        _ = runtime.drain { _ in }
    }
}
