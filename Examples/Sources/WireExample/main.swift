// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

let payload = #"{"object":{"objectId":"00000000-0000-4000-8000-000000000001"}}"#
let bytes = Array(payload.utf8)
let result = bytes.withUnsafeBufferPointer { buffer -> String in
    guard let baseAddress = buffer.baseAddress else { return "empty" }
    let reader = WireReader(bytes: baseAddress, length: buffer.count)
    return reader.readRaw("object") == nil ? "missing" : "found"
}
print("Result: \(result)")
