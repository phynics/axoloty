// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Minimal release consumer for AxolotyWire (issue #299).
//
// Exercises one stable public path so dead stripping cannot erase the product.
// The binary size of this consumer captures the AxolotyWire dependency
// closure in isolation — it must contain no host runtime packages (mqtt-nio,
// swift-nio, NIOSSL, etc.).

import AxolotyWire

let payload = #"{"object":{"objectId":"00000000-0000-4000-8000-000000000001"}}"#
let bytes = Array(payload.utf8)
let result = bytes.withUnsafeBufferPointer { buffer -> String in
    guard let base = buffer.baseAddress else { return "nil" }
    let reader = WireReader(bytes: base, length: buffer.count)
    let object = reader.readRaw("object")
    return object != nil ? "found" : "nil"
}
print("AXOLOTY_WIRE_CONSUMER_OK: \(result)")
