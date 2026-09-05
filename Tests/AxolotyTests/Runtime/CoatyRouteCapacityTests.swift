// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyProtocol
import AxolotyWire

/// Regression coverage for ``CoatyRoute/route(for:namespace:eventTypeFilter:eventTypeFilterKind:)``.
///
/// The builder writes into a hand-sized buffer computed from a byte-budget
/// formula; these tests confirm the returned topic is truncated to the bytes
/// ``TopicBuilder`` actually wrote (never to the raw allocation) across the
/// shapes most likely to stress that formula: a multi-byte UTF-8 namespace,
/// a long object-type filter, and the correlated (request/response) layout.
@Suite("Coaty route capacity")
struct CoatyRouteCapacityTests {
    private static func sourceID() throws -> UUID16 {
        try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
    }

    private static func correlationID() throws -> UUID16 {
        try #require(UUID16(parsing: "55555555-5555-4555-8555-555555555555"))
    }

    /// Asserts the topic carries no trailing NUL bytes and validates as a
    /// well-formed Coaty topic under a generous host-runtime budget.
    private static func assertWellFormed(_ topic: String) throws {
        #expect(!topic.utf8.contains(0), "topic must not contain a trailing NUL byte: \(topic.debugDescription)")
        let bytes = Array(topic.utf8)
        try bytes.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) in
            let view = TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
            try view.validate(maximumTopicLength: 512)
        }
    }

    @Test("topic truncates to the bytes written for a multi-byte UTF-8 namespace")
    func topicTruncatesForMultiByteNamespace() throws {
        let id = try Self.sourceID()
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        // "café-日本語" mixes 1-, 2-, and 3-byte UTF-8 sequences so the
        // namespace's UTF-8 byte count diverges sharply from its character
        // count, stressing the hand-rolled capacity arithmetic.
        let namespace = "café-日本語"
        let topic = try CoatyRoute.route(for: key, namespace: namespace)
        #expect(topic == "coaty/3/\(namespace)/ADV/44444444-4444-4444-8444-444444444444")
        try Self.assertWellFormed(topic)
    }

    @Test("topic truncates to the bytes written for a long object-type filter")
    func topicTruncatesForLongObjectTypeFilter() throws {
        let id = try Self.sourceID()
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        let filter = "com.example.axoloty.telemetry.VeryLongQualifiedObjectTypeNameForStressTesting"
        let topic = try CoatyRoute.route(
            for: key,
            namespace: "test",
            eventTypeFilter: Array(filter.utf8),
            eventTypeFilterKind: .objectType
        )
        #expect(topic == "coaty/3/test/ADV::\(filter)/44444444-4444-4444-8444-444444444444")
        try Self.assertWellFormed(topic)
    }

    @Test("topic truncates to the bytes written for the correlated request/response shape")
    func topicTruncatesForCorrelatedShape() throws {
        let id = try Self.sourceID()
        let correlation = try Self.correlationID()
        let key = try ProtocolRoutingKey(capability: .discover, sourceID: id, correlationID: correlation)
        let topic = try CoatyRoute.route(for: key, namespace: "test")
        #expect(topic == "coaty/3/test/DSC/44444444-4444-4444-8444-444444444444/55555555-5555-4555-8555-555555555555")
        try Self.assertWellFormed(topic)
    }

    @Test("topic combines a multi-byte namespace, object-type filter, and correlation without corruption")
    func topicTruncatesForCombinedWorstCaseShape() throws {
        let id = try Self.sourceID()
        let correlation = try Self.correlationID()
        let key = try ProtocolRoutingKey(capability: .query, sourceID: id, correlationID: correlation)
        let namespace = "工場-café"
        let filter = "com.example.axoloty.VeryLongQualifiedObjectTypeName"
        let topic = try CoatyRoute.route(
            for: key,
            namespace: namespace,
            eventTypeFilter: Array(filter.utf8),
            eventTypeFilterKind: .objectType
        )
        #expect(topic == "coaty/3/\(namespace)/QRY::\(filter)/44444444-4444-4444-8444-444444444444/55555555-5555-4555-8555-555555555555")
        try Self.assertWellFormed(topic)
    }
}
