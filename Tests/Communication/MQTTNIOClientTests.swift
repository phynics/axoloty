// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import NIO
import Testing

@Suite
struct MQTTNIOClientTests {
    @Test
    func validUTF8PayloadReadsByteBufferWithoutLossyDecoding() {
        var validPayload = ByteBufferAllocator().buffer(capacity: 5)
        validPayload.writeBytes([0x48, 0x65, 0x6C, 0x6C, 0x6F])

        var invalidPayload = ByteBufferAllocator().buffer(capacity: 1)
        invalidPayload.writeBytes([0xFF])

        #expect(MQTTNIOClient.validUTF8Payload(from: validPayload) == "Hello")
        #expect(MQTTNIOClient.validUTF8Payload(from: invalidPayload) == nil)
    }
}
