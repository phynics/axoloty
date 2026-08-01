// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

@_cdecl("axoloty_native_wire_codec_spike")
public func axolotyNativeWireCodecSpike(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int32
) -> Int32 {
    var reader = NativeStrictReader(bytes: bytes, length: Int(length))
    return (try? reader.decodeAssociate()) != nil ? 1 : 0
}
