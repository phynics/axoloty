// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if EMBEDDED_MQTT_HOST_TEST
// Host self-tests compile this firmware-local overlay without resolving the
// Embedded Swift package graph. Keep the production limits in sync here.
private enum WireBufferConfig {
    static let maxTopicLength = 256
    static let maxPayloadSize = 2_048
}
#else
import AxolotyWire
#endif

#if EMBEDDED_MQTT_HOST_TEST
// The host fixture supplies these symbols. The production build receives the
// same declarations from BridgingHeader.h, so the seam adds no runtime layer.
@_silgen_name("axoloty_mqtt_configure_last_will")
private func axoloty_mqtt_configure_last_will(_ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32) -> Int32
@_silgen_name("axoloty_mqtt_connect_wait")
private func axoloty_mqtt_connect_wait(_ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_mqtt_subscribe_wait")
private func axoloty_mqtt_subscribe_wait(_ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_mqtt_publish")
private func axoloty_mqtt_publish(_ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32) -> Int32
@_silgen_name("axoloty_mqtt_wait_loopback")
private func axoloty_mqtt_wait_loopback(_ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_mqtt_reconnect_wait")
private func axoloty_mqtt_reconnect_wait(_ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_mqtt_disconnect")
private func axoloty_mqtt_disconnect() -> Int32
#endif

/// Bounded, synchronous MQTT operations for the single-device embedded gate.
///
/// ESP-MQTT owns the client handle and callback in C. Every byte buffer passed
/// here is consumed synchronously and is never retained by this value.
struct EmbeddedMQTTClient {
    private enum State {
        case idle
        case connected
        case subscribed
        case disconnected
    }

    private var state = State.idle

    init() {}

    mutating func configureLastWill(
        topic: UnsafePointer<UInt8>, topicLength: Int32,
        payload: UnsafePointer<UInt8>, payloadLength: Int32
    ) -> Bool {
        guard state == .idle, topicLength > 0,
              topicLength <= Int32(WireBufferConfig.maxTopicLength),
              payloadLength >= 0, payloadLength <= Int32(WireBufferConfig.maxPayloadSize) else { return false }
        return axoloty_mqtt_configure_last_will(topic, topicLength, payload, payloadLength) != 0
    }

    mutating func connect(deadlineMS: UInt32) -> Bool {
        guard state == .idle, axoloty_mqtt_connect_wait(deadlineMS) != 0 else { return false }
        state = .connected
        return true
    }

    mutating func subscribe(
        topic: UnsafePointer<UInt8>, topicLength: Int32,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .connected, topicLength > 0,
              topicLength <= Int32(WireBufferConfig.maxTopicLength),
              axoloty_mqtt_subscribe_wait(topic, topicLength, deadlineMS) != 0 else { return false }
        state = .subscribed
        return true
    }

    func publish(
        topic: UnsafePointer<UInt8>, topicLength: Int32,
        payload: UnsafePointer<UInt8>, payloadLength: Int32
    ) -> Bool {
        guard state == .subscribed, topicLength > 0,
              topicLength <= Int32(WireBufferConfig.maxTopicLength),
              payloadLength >= 0, payloadLength <= Int32(WireBufferConfig.maxPayloadSize) else { return false }
        return axoloty_mqtt_publish(topic, topicLength, payload, payloadLength) != 0
    }

    func waitForLoopback(deadlineMS: UInt32) -> Bool {
        state == .subscribed && axoloty_mqtt_wait_loopback(deadlineMS) != 0
    }

    func waitForReconnect(deadlineMS: UInt32) -> Bool {
        state == .subscribed && axoloty_mqtt_reconnect_wait(deadlineMS) != 0
    }

    mutating func disconnect() -> Bool {
        guard state == .connected || state == .subscribed else { return false }
        guard axoloty_mqtt_disconnect() != 0 else { return false }
        state = .disconnected
        return true
    }
}
