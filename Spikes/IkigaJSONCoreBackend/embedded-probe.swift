// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_cdecl("axoloty_ikiga_json_core_spike")
public func axolotyIkigaJSONCoreSpike(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int32
) -> Int32 {
    tokenizeJSON(bytes, length: Int(length)) ? 1 : 0
}
