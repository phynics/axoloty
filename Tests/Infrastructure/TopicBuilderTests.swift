// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing
import AxolotyWire

/// Tests for the host-runtime topic builders, validators, and MQTT filter
/// matching on ``TopicBuilder``, plus round-trip parsing through ``TopicView``.
///
/// These replaced the builder/validation/matching logic that previously
/// lived on the removed `CommunicationTopic` class.
@Suite
struct TopicBuilderTests {
    private let sourceId = CoatyUUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab")!

    @Test
    func testPublishTopicRoundTripsThroughTopicView() throws {
        let topicString = TopicBuilder.publishTopic(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .advertise,
            eventTypeFilter: "com.example.Sensor"
        )

        #expect(topicString == "coaty/3/factory/ADV:com.example.Sensor/\(sourceId.string)")

        let bytes = Array(topicString.utf8)
        let view = try bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }

        #expect(view.eventType == .advertise)
        #expect(try #require(view.eventTypeFilter).asString() == "com.example.Sensor")
        #expect(try #require(view.namespaceLevel).asString() == "factory")
        #expect(try #require(view.sourceIdLevel).asString() == sourceId.string)
        #expect(view.correlationIdLevel == nil)
    }

    @Test
    func testTwoWayPublishAndSubscribeTopicsIncludeCorrelationLevel() throws {
        let publication = TopicBuilder.publishTopic(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .discover,
            correlationId: "request-42"
        )
        #expect(publication == "coaty/3/factory/DSC/\(sourceId.string)/request-42")

        let bytes = Array(publication.utf8)
        let view = try bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }
        #expect(try #require(view.correlationIdLevel).asString() == "request-42")

        #expect(TopicBuilder.subscribeTopic(
            eventType: .resolve,
            namespace: "factory",
            correlationId: "request-42"
        ) == "coaty/3/factory/RSV/+/request-42")
        #expect(TopicBuilder.subscribeTopic(eventType: .discover) == "coaty/3/+/DSC/+/+")
    }

    @Test
    func testValidateRejectsStructurallyInvalidTopics() {
        let invalidTopics = [
            "coaty/3/factory/ADV/\(sourceId.string)",
            "coaty/3/factory/ADV:type/\(sourceId.string)/unexpected",
            "coaty/3/factory/DSC/\(sourceId.string)",
            "coaty/3/factory/DSC:type/\(sourceId.string)/correlation",
            "coaty/3/factory/UNKNOWN/\(sourceId.string)",
            "coaty/3/factory/DAD/not-a-uuid",
            "other/3/factory/DAD/\(sourceId.string)",
            "coaty/3//DAD/\(sourceId.string)"
        ]

        for topic in invalidTopics {
            #expect(throws: (any Error).self, "Expected rejection of \(topic)") {
                try TopicBuilder.validate(topic)
            }
        }
    }

    @Test
    func testTopicValidation() {
        #expect(TopicBuilder.isValidPublicationTopic("sensors/temperature"))
        #expect(!TopicBuilder.isValidPublicationTopic("sensors/+"))
        #expect(!TopicBuilder.isValidPublicationTopic("sensors/#"))
        #expect(!TopicBuilder.isValidPublicationTopic(""))
        #expect(TopicBuilder.isValidSubscriptionTopic("sensors/+/value"))
        #expect(!TopicBuilder.isValidSubscriptionTopic("bad\u{0000}topic"))
    }

    @Test
    func testMQTTWildcardMatching() {
        #expect(TopicBuilder.matches("a/b/c", "a/+/c"))
        #expect(TopicBuilder.matches("a/b/c/d", "a/b/#"))
        #expect(TopicBuilder.matches("a//b", "a/+/b"))
        #expect(!TopicBuilder.matches("a/b/c/d", "a/+/c"))
        #expect(!TopicBuilder.matches("a/b", "a/b/c"))
        #expect(!TopicBuilder.matches("", "#"))
    }

    @Test
    func testSingleLevelWildcardDoesNotMatchMissingLevel() {
        #expect(!TopicBuilder.matches("ac1a0ba", "+/+/#"))
        #expect(!TopicBuilder.matches("a/", "+/+/+/#"))
        #expect(TopicBuilder.matches("a/", "a/+"))
        #expect(TopicBuilder.matches("a//b", "+/+/b"))
        #expect(TopicBuilder.matches("a", "a/#"))
        #expect(TopicBuilder.matches("a/", "+/+/#"))
    }
}
