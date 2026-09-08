// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_silgen_name("host_mqtt_reset")
private func hostMQTTReset()
@_silgen_name("host_mqtt_set_failures")
private func hostMQTTSetFailures(_ failures: UInt32)
@_silgen_name("host_mqtt_call_count")
private func hostMQTTCallCount(_ operation: UInt32) -> UInt32
@_silgen_name("host_mqtt_resubscription_count")
private func hostMQTTResubscriptionCount() -> UInt32
@_silgen_name("host_identity_tests")
private func hostIdentityTests() -> Int32
@_silgen_name("host_callback_validation_tests")
private func hostCallbackValidationTests() -> Int32

@main
private struct EmbeddedMQTTHostTest {
    private static let failWill: UInt32 = 1 << 0
    private static let failConnect: UInt32 = 1 << 1
    private static let failSubscribe: UInt32 = 1 << 2
    private static let failPublish: UInt32 = 1 << 3
    private static let failLoopback: UInt32 = 1 << 4
    private static let failReconnect: UInt32 = 1 << 5
    private static let failDisconnect: UInt32 = 1 << 6

    static func main() {
        precondition(hostIdentityTests() != 0, "client identity vectors")
        precondition(hostCallbackValidationTests() != 0, "callback validation vectors")
        hostMQTTReset()

        let topic = Array("coaty/test/topic".utf8)
        let payload = Array("payload".utf8)
        topic.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                let topicPointer = topicBuffer.baseAddress!
                let payloadPointer = payloadBuffer.baseAddress!
                var client = EmbeddedMQTTClient()

                // Invalid order is rejected before entering the HAL.
                precondition(!client.disconnect())
                precondition(!client.publish(topic: topicPointer, topicLength: 1, payload: payloadPointer, payloadLength: 1))
                precondition(!client.waitForLoopback(deadlineMS: 1))
                precondition(!client.waitForReconnect(deadlineMS: 1))
                precondition(hostMQTTCallCount(3) == 0 && hostMQTTCallCount(4) == 0)

                hostMQTTSetFailures(failWill)
                precondition(!client.configureLastWill(
                    topic: topicPointer, topicLength: Int32(topic.count),
                    payload: payloadPointer, payloadLength: Int32(payload.count)))
                hostMQTTSetFailures(0)
                precondition(client.configureLastWill(
                    topic: topicPointer, topicLength: Int32(topic.count),
                    payload: payloadPointer, payloadLength: Int32(payload.count)))
                precondition(hostMQTTCallCount(0) == 2)

                // A failed connect keeps the client in idle, so retry is safe.
                hostMQTTSetFailures(failConnect)
                precondition(!client.connect(deadlineMS: 1))
                hostMQTTSetFailures(0)
                precondition(client.connect(deadlineMS: 1))
                precondition(!client.configureLastWill(
                    topic: topicPointer, topicLength: 1,
                    payload: payloadPointer, payloadLength: 1))

                // A failed subscribe keeps the client connected.
                hostMQTTSetFailures(failSubscribe)
                precondition(!client.subscribe(topic: topicPointer, topicLength: Int32(topic.count), deadlineMS: 1))
                hostMQTTSetFailures(0)
                precondition(client.subscribe(topic: topicPointer, topicLength: Int32(topic.count), deadlineMS: 1))

                hostMQTTSetFailures(failPublish | failLoopback)
                precondition(!client.publish(
                    topic: topicPointer, topicLength: Int32(topic.count),
                    payload: payloadPointer, payloadLength: Int32(payload.count)))
                precondition(!client.waitForLoopback(deadlineMS: 1))
                hostMQTTSetFailures(0)
                precondition(client.publish(
                    topic: topicPointer, topicLength: Int32(topic.count),
                    payload: payloadPointer, payloadLength: Int32(payload.count)))
                precondition(client.waitForLoopback(deadlineMS: 1))

                // Reconnect remains subscribed and asks the HAL to resubscribe.
                hostMQTTSetFailures(failReconnect)
                precondition(!client.waitForReconnect(deadlineMS: 1))
                hostMQTTSetFailures(0)
                precondition(client.waitForReconnect(deadlineMS: 1))
                precondition(hostMQTTResubscriptionCount() == 1)

                // Bounds are enforced before every transport call.
                precondition(!client.publish(
                    topic: topicPointer, topicLength: 257,
                    payload: payloadPointer, payloadLength: Int32(payload.count)))
                precondition(!client.publish(
                    topic: topicPointer, topicLength: Int32(topic.count),
                    payload: payloadPointer, payloadLength: 2_049))
                precondition(hostMQTTCallCount(3) == 2)

                hostMQTTSetFailures(failDisconnect)
                precondition(!client.disconnect())
                hostMQTTSetFailures(0)
                precondition(client.disconnect())
                precondition(!client.disconnect())
                precondition(!client.connect(deadlineMS: 1))
                precondition(hostMQTTCallCount(6) == 2)
            }
        }
    }
}
