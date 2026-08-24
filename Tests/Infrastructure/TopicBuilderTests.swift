// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Exercises the portable fixed-buffer topic writer and its borrowed parser.
///
/// This is the maintained replacement for the removed `CommunicationTopic`
/// contract. The test name is intentionally explicit so tier filters cannot
/// silently revive the legacy Foundation-backed API.
@Suite
struct PortableTopicBuilderTests {
    private let sourceID = UUID16(parsing: "01234567-89ab-4cde-8fab-0123456789ab")!
    private let correlationID = UUID16(parsing: "fedcba98-7654-4321-8fed-cba987654321")!

    @Test
    func writesCanonicalOneWayTopicAndRoundTripsThroughView() throws {
        let topic = try makeTopic { builder in
            try builder.writePrefix()
            try builder.writeNamespace("factory")
            let filter = Array("com.example.Sensor".utf8)
            try filter.withUnsafeBufferPointer { buffer in
                try builder.writeEventType(
                    .advertise,
                    filter: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
                )
            }
            try builder.writeSourceId(sourceID)
        }

        #expect(topic == "coaty/3/factory/ADV:com.example.Sensor/01234567-89ab-4cde-8fab-0123456789ab")
        try withTopicView(topic) { view in
            try view.validate()
            #expect(view.eventType == .advertise)
            #expect(view.eventTypeFilter?.asString() == "com.example.Sensor")
            #expect(view.namespaceLevel?.asString() == "factory")
            #expect(view.sourceIdLevel?.asString() == "01234567-89ab-4cde-8fab-0123456789ab")
            #expect(view.correlationIdLevel == nil)
        }
    }

    @Test
    func writesCanonicalTwoWayTopicWithCorrelationLevel() throws {
        let topic = try makeTopic { builder in
            try builder.writePrefix()
            try builder.writeNamespace("factory")
            try builder.writeEventType(.discover)
            try builder.writeSourceId(sourceID)
            try builder.writeCorrelationId(correlationID)
        }

        #expect(topic == "coaty/3/factory/DSC/01234567-89ab-4cde-8fab-0123456789ab/fedcba98-7654-4321-8fed-cba987654321")
        try withTopicView(topic) { view in
            try view.validate()
            #expect(view.eventType == .discover)
            #expect(view.correlationIdLevel?.asString() == "fedcba98-7654-4321-8fed-cba987654321")
        }
    }

    @Test
    func rejectsStructurallyInvalidTopics() {
        let invalidTopics = [
            "coaty/3/factory/ADV/01234567-89ab-4cde-8fab-0123456789ab/extra",
            "coaty/3/factory/DSC/01234567-89ab-4cde-8fab-0123456789ab",
            "coaty/3/factory/UNKNOWN/01234567-89ab-4cde-8fab-0123456789ab",
            "coaty/3/factory/DAD/not-a-uuid",
            "other/3/factory/DAD/01234567-89ab-4cde-8fab-0123456789ab",
            "coaty/3//DAD/01234567-89ab-4cde-8fab-0123456789ab",
        ]

        for topic in invalidTopics {
            #expect(throws: (any Error).self, "Expected rejection of \(topic)") {
                try withTopicView(topic) { view in try view.validate() }
            }
        }
    }

    @Test
    func rejectsBufferOverflowWithoutAdvancingPastCapacity() throws {
        var bytes = [UInt8](repeating: 0, count: 5)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            var builder = TopicBuilder(buffer: buffer.baseAddress!, capacity: buffer.count)

            #expect(throws: WireEncodeError.self) { try builder.writePrefix() }
            #expect(builder.position == 5)
        }
    }

    @Test
    func parsesRawTopicsWithoutInventingCoatyStructure() throws {
        try withTopicView("application/device/temperature") { view in
            #expect(view.isRawTopic)
            #expect(view.eventType == nil)
            #expect(view.namespaceLevel?.asString() == "temperature")
        }
    }

    private func makeTopic(
        _ body: (inout TopicBuilder) throws -> Void
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 256)
        return try bytes.withUnsafeMutableBufferPointer { buffer in
            var builder = TopicBuilder(buffer: buffer.baseAddress!, capacity: buffer.count)
            try body(&builder)
            return builder.build().asString()
        }
    }

    private func withTopicView(
        _ topic: String,
        _ body: (TopicView) throws -> Void
    ) rethrows {
        let bytes = Array(topic.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let view = TopicView(topicBytes: buffer.baseAddress!, length: buffer.count)
            try body(view)
        }
    }
}
