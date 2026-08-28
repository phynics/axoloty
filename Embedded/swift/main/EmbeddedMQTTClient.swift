// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

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
              payloadLength >= 0, payloadLength <= 2_048 else { return false }
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
              payloadLength >= 0, payloadLength <= 2_048 else { return false }
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
