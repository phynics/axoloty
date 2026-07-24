// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Host-runtime adapter that bridges `BorrowedMessage` to the existing
/// `CommunicationStreams` infrastructure.
///
/// When `dispatch(_:)` is called with a borrowed message, this adapter:
/// 1. Converts the topic bytes to a `String` (heap allocation).
/// 2. Parses the topic via `CommunicationTopic` (heap allocation).
/// 3. Converts the payload bytes to a UTF-8 `String` (heap allocation).
/// 4. Creates a `ParsedMQTTMessage` and sends it through the `Broadcast`
///    actor (actor hop).
///
/// This is the bridge that lets routing code written against `MessageRouter`
/// run on the host runtime. The allocation cost is the existing production
/// path's cost — the embedded adapter avoids it entirely.
///
/// - Note: This adapter does not replace the existing `MQTTNIOClient` flow.
///   It provides a `MessageRouter`-compatible entry point for code that
///   targets both host and embedded. The production cutover (Phase E) will
///   route the MQTT client's `handlePublish` through this interface.
public final class HostMessageRouter: MessageRouter, @unchecked Sendable {
    private let streams: CommunicationStreams

    init(streams: CommunicationStreams) {
        self.streams = streams
    }

    public func dispatch(_ message: BorrowedMessage) {
        // Convert borrowed topic bytes to owned String
        let topicString = message.topic.withBytes { ptr, len in
            ptr.withMemoryRebound(to: UInt8.self, capacity: len) { buf in
                String(bytes: UnsafeBufferPointer(start: buf, count: len), encoding: .utf8) ?? ""
            }
        }

        // Convert borrowed payload bytes to owned String
        let payloadString = message.payload.withBytes { ptr, len in
            ptr.withMemoryRebound(to: UInt8.self, capacity: len) { buf in
                String(bytes: UnsafeBufferPointer(start: buf, count: len), encoding: .utf8) ?? ""
            }
        }

        // Parse the topic (same allocation path as MQTTNIOClient.handlePublish)
        guard let topic = try? CommunicationTopic(topicString) else {
            return
        }

        let parsed = ParsedMQTTMessage(topic: topic, payload: payloadString)

        // Send through the existing Broadcast actor infrastructure
        _Concurrency.Task { @MainActor [streams] in
            await streams.parsedMQTTMessages.send(parsed)
        }
    }
}
