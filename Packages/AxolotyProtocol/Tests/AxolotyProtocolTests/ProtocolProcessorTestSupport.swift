// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyProtocol
import AxolotyWire

struct UnrelatedRouteClassifier: ProtocolRouteClassifier {
    func classify(_: ByteSlice) -> ProtocolRouteClassification { .unrelated }
}

struct MultiExternalRouteClassifier: ProtocolRouteClassifier {
    func classify(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.equals("external/io-a") || route.equals("external/io-b") ? .external : .coaty
    }
}

func protocolSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

func withStaticPayload<R>(_ body: (ByteSlice) -> R) -> R {
    let payload: StaticString = "{}"
    return body(ByteSlice(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount))
}

func withResponseFrame<R>(
    correlation: String,
    event: String = "RSV",
    payload explicitPayload: String? = nil,
    _ body: (BorrowedProtocolFrame) throws -> R
) throws -> R {
    let topic = Array("coaty/3/test/\(event)/00000000-0000-0000-0000-000000000000/\(correlation)".utf8)
    let payloadString: String
    if let explicitPayload {
        payloadString = explicitPayload
    } else {
        switch event {
        case "RSV": payloadString = "{\"object\":{}}"
        case "RTV": payloadString = "{\"objects\":[]}"
        case "UPD": payloadString = "{\"object\":{}}"
        default: payloadString = "{}"
        }
    }
    let payload = Array(payloadString.utf8)
    return try topic.withUnsafeBufferPointer { topicBuffer in
        try payload.withUnsafeBufferPointer { payloadBuffer in
            let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
            let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
        }
    }
}

func withBorrowedBytes<R>(_ value: String, _ body: (ByteSlice) throws -> R) throws -> R {
    let bytes = Array(value.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        try body(ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

func withBorrowedFrame<R>(
    topic: String,
    payload: String,
    _ body: (BorrowedProtocolFrame) throws -> R
) throws -> R {
    let topicBytes = Array(topic.utf8)
    let payloadBytes = Array(payload.utf8)
    return try topicBytes.withUnsafeBufferPointer { topicBuffer in
        try payloadBytes.withUnsafeBufferPointer { payloadBuffer in
            let view = TopicView(topicBytes: topicBuffer.baseAddress!, length: topicBuffer.count)
            let bytes = ByteSlice(bytes: payloadBuffer.baseAddress!, length: payloadBuffer.count)
            return try body(try BorrowedProtocolFrame(topic: view, payload: bytes))
        }
    }
}
