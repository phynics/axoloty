// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyCoatyModels
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire

@inline(never)
func axoloty_coaty_models_embedded_link_probe() -> Bool {
    guard IoSource.schema.fieldCount == 5 else { return false }

    let filter: StaticString = "{\"conditions\":[\"value\",[7,1]]}"
    let filterBytes = ByteSlice(bytes: filter.utf8Start, length: filter.utf8CodeUnitCount)
    let adapter: CoatyFilterAdapter<16, 16, 16, 64>
    do throws(ProtocolError) {
        adapter = try CoatyFilterAdapter(decoding: filterBytes)
    } catch {
        return false
    }

    let objectJSON: StaticString = "{\"value\":1}"
    let object: BoundedDynamicObject<128, 4>
    do throws(ObjectError) {
        object = try BoundedDynamicObject(decoding: ByteSlice(
            bytes: objectJSON.utf8Start,
            length: objectJSON.utf8CodeUnitCount
        ))
    } catch {
        return false
    }
    guard adapter.matches(object: object) else { return false }

    var output = InlineArray<128, UInt8>(repeating: 0)
    return withUnsafeMutableBytes(of: &output) { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return false }
        var writer = WireWriter(
            buffer: baseAddress.assumingMemoryBound(to: UInt8.self),
            capacity: rawBuffer.count
        )
        do throws(WireEncodeError) {
            try adapter.encode(to: &writer)
        } catch {
            return false
        }
        return writer.position > 0
    }
}
