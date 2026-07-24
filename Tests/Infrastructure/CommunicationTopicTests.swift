// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty

@Suite
struct CommunicationTopicTests {
    private let sourceId = CoatyUUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab")!

    @Test

    func testPublishTopicRoundTripsThroughParser() throws {
        let topicString = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .Advertise,
            eventTypeFilter: "com.example.Sensor"
        )

        #expect((topicString) == ("coaty/3/factory/ADV:com.example.Sensor/\(sourceId.string)"))

        let topic = try CommunicationTopic(topicString)
        #expect((topic.protocolVersion) == (3))
        #expect((topic.namespace) == ("factory"))
        #expect((topic.eventType) == (.Advertise))
        #expect((topic.eventTypeFilter) == ("com.example.Sensor"))
        #expect((topic.sourceId) == (sourceId))
        #expect((topic.correlationId) == nil)
    }

    @Test

    func testTwoWayPublishAndSubscribeTopicsIncludeCorrelationLevel() throws {
        let publication = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .Discover,
            correlationId: "request-42"
        )
        #expect((publication) == ("coaty/3/factory/DSC/\(sourceId.string)/request-42"))
        #expect((try CommunicationTopic(publication).correlationId) == ("request-42"))

        #expect((CommunicationTopic.createTopicStringByLevelsForSubscribe(
                eventType: .Resolve,
                namespace: "factory",
                correlationId: "request-42"
            )) == ("coaty/3/factory/RSV/+/request-42"))
        #expect((CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Discover)) == ("coaty/3/+/DSC/+/+"))
    }

    @Test

    func testParserRejectsStructurallyInvalidTopics() {
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
            #expect(throws: (any Error).self, "Expected rejection of \(topic)") { try CommunicationTopic(topic) }
        }
    }

    @Test

    func testTopicValidationAndRawClassification() {
        #expect(CommunicationTopic.isValidPublicationTopic("sensors/temperature"))
        #expect(!(CommunicationTopic.isValidPublicationTopic("sensors/+")))
        #expect(!(CommunicationTopic.isValidPublicationTopic("sensors/#")))
        #expect(!(CommunicationTopic.isValidPublicationTopic("")))
        #expect(CommunicationTopic.isValidSubscriptionTopic("sensors/+/value"))
        #expect(!(CommunicationTopic.isValidSubscriptionTopic("bad\u{0000}topic")))
        // isRawTopic is now tested via TopicView in WireCodecTests
    }

    @Test

    func testMQTTWildcardMatching() {
        #expect(CommunicationTopic.matches("a/b/c", "a/+/c"))
        #expect(CommunicationTopic.matches("a/b/c/d", "a/b/#"))
        #expect(CommunicationTopic.matches("a//b", "a/+/b"))
        #expect(!(CommunicationTopic.matches("a/b/c/d", "a/+/c")))
        #expect(!(CommunicationTopic.matches("a/b", "a/b/c")))
        #expect(!(CommunicationTopic.matches("", "#")))
    }

    @Test

    func testSingleLevelWildcardDoesNotMatchMissingLevel() {
        #expect(!(CommunicationTopic.matches("ac1a0ba", "+/+/#")))
        #expect(!(CommunicationTopic.matches("a/", "+/+/+/#")))
        #expect(CommunicationTopic.matches("a/", "a/+"))
        #expect(CommunicationTopic.matches("a//b", "+/+/b"))
        #expect(CommunicationTopic.matches("a", "a/#"))
        #expect(CommunicationTopic.matches("a/", "+/+/#"))
    }
}
