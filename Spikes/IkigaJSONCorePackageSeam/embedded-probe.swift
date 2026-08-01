// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_cdecl("axoloty_json_core_package_probe")
public func axolotyJSONCorePackageProbe(
    _ bytes: UnsafePointer<UInt8>,
    _ count: Int32
) -> Int32 {
    validJSON(bytes, count: Int(count)) ? 1 : 0
}
