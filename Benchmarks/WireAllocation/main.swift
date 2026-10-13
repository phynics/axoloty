// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Dedicated host allocation-regression probe for the AxolotyWire borrowed
// decode + shared protocol processor hot path (issue #490).
//
// This executable performs ONLY a warmed steady-state decode/route pass, so a
// malloc-counting instrument (heaptrack) measures the hot path in isolation.
// The number of hot-path iterations is passed as the first argument, so the
// regression gate can compare allocation counts at two widely different
// iteration counts and reject any per-message allocation (which would scale
// the total count with the argument).
//
// The optional second argument selects the wire profile: `json` (default)
// drives `coaty/3`, `cbor` drives `axoloty/1`. The two legs share one DTO and
// one processor, so the gate proves the profile seam adds no per-message
// allocation either. The CBOR payload is transcoded from the JSON fixture at
// startup, outside the measured window.
//
// Usage:
//   WireAllocation [iterations] [json|cbor]   default 50_000, json
//
// It emits no per-iteration JSON; the check script wraps it in heaptrack.

import AxolotyWire
import AxolotyProtocol

@inline(never)
func hotPath(
    codec: WireCodec,
    topicBuffer: UnsafePointer<UInt8>,
    topicLength: Int,
    payloadBuffer: UnsafePointer<UInt8>,
    payloadLength: Int,
    iterations: Int
) -> UInt32 {
    var sink: UInt32 = 0
    var processor = ProtocolProcessor<16>(wireCodec: codec)
    for _ in 0..<iterations {
        let message = BorrowedMessage(
            topicBytes: topicBuffer, topicLength: topicLength,
            payloadBytes: payloadBuffer, payloadLength: payloadLength
        )
        // DTO decode through the borrowed reader.
        if (try? AssociateWireData(from: message.reader())) != nil { sink &+= 1 }
        // Shared fixed-inline protocol processing.
        var actionSink = InlineProtocolActionSink<1>()
        if let frame = try? BorrowedProtocolFrame(topic: message.topic, payload: message.payload) {
            if processor.processInbound(.profile(frame), nowMS: 1, sink: &actionSink) == .accepted { sink &+= 1 }
        }
    }
    return sink
}

/// Re-encodes the JSON associate fixture as deterministic CBOR so the probe
/// drives the same DTO and processor over the `axoloty/1` profile.
///
/// This runs once, before the measured window, so the temporary buffers do
/// not contribute to the steady-state allocation count.
func cborAssociatePayload(jsonBytes: [UInt8]) -> [UInt8] {
    let jsonCodec = WireCodec(profile: .coaty3JSON)
    let data: AssociateWireData = jsonBytes.withUnsafeBufferPointer { buffer in
        // swiftlint:disable:next force_try
        try! AssociateWireData(from: jsonCodec.reader(bytes: buffer.baseAddress!, length: buffer.count))
    }
    var output = [UInt8](repeating: 0, count: 512)
    let length: Int = output.withUnsafeMutableBufferPointer { buffer in
        var writer = WireCodec(profile: .axoloty1CBOR).writer(
            buffer: buffer.baseAddress!, capacity: buffer.count
        )
        // swiftlint:disable:next force_try
        try! data.encode(to: &writer)
        return writer.position
    }
    return Array(output[0..<length])
}

let arguments = Array(CommandLine.arguments.dropFirst())
let iterations = Int(arguments.first ?? "50000")!
let profile: WireProfile = arguments.count > 1 && arguments[1] == "cbor" ? .axoloty1CBOR : .coaty3JSON
let codec = WireCodec(profile: profile)
let jsonPayload =
    "{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"33333333-3333-4333-8333-333333333333\",\"isExternalRoute\":true}"
let topic: String
let payloadBytes: [UInt8]
switch profile {
case .coaty3JSON:
    topic = "coaty/3/ns/ASC:filter/source-id"
    payloadBytes = Array(jsonPayload.utf8)
case .axoloty1CBOR:
    topic = "axoloty/1/ns/ASC:filter/33333333-3333-4333-8333-333333333333"
    payloadBytes = cborAssociatePayload(jsonBytes: Array(jsonPayload.utf8))
}
let topicBytes = Array(topic.utf8)

var total: UInt32 = 0
payloadBytes.withUnsafeBufferPointer { pb in
    topicBytes.withUnsafeBufferPointer { tb in
        // Warm-up pass (pay any one-time setup / first-touch COW before the
        // measured window so it cannot be mistaken for a per-iteration cost).
        _ = hotPath(
            codec: codec,
            topicBuffer: tb.baseAddress!, topicLength: tb.count,
            payloadBuffer: pb.baseAddress!, payloadLength: pb.count,
            iterations: 1_000
        )
        // Measured steady-state pass at the requested iteration count.
        total = hotPath(
            codec: codec,
            topicBuffer: tb.baseAddress!, topicLength: tb.count,
            payloadBuffer: pb.baseAddress!, payloadLength: pb.count,
            iterations: max(1, iterations)
        )
    }
}
// Keep the result live so the compiler cannot elide the loop.
if total == UInt32.max { print(total) }
