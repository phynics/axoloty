// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import XCTest
@testable import CoatySwift

final class CommunicationTopicTests: XCTestCase {
    private let sourceId = CoatyUUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab")!

    func testPublishTopicRoundTripsThroughParser() throws {
        let topicString = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .Advertise,
            eventTypeFilter: "com.example.Sensor"
        )

        XCTAssertEqual(topicString, "coaty/3/factory/ADV:com.example.Sensor/\(sourceId.string)")

        let topic = try CommunicationTopic(topicString)
        XCTAssertEqual(topic.protocolVersion, 3)
        XCTAssertEqual(topic.namespace, "factory")
        XCTAssertEqual(topic.eventType, .Advertise)
        XCTAssertEqual(topic.eventTypeFilter, "com.example.Sensor")
        XCTAssertEqual(topic.sourceId, sourceId)
        XCTAssertNil(topic.correlationId)
    }

    func testTwoWayPublishAndSubscribeTopicsIncludeCorrelationLevel() throws {
        let publication = CommunicationTopic.createTopicStringByLevelsForPublish(
            namespace: "factory",
            sourceId: sourceId,
            eventType: .Discover,
            correlationId: "request-42"
        )
        XCTAssertEqual(publication, "coaty/3/factory/DSC/\(sourceId.string)/request-42")
        XCTAssertEqual(try CommunicationTopic(publication).correlationId, "request-42")

        XCTAssertEqual(
            CommunicationTopic.createTopicStringByLevelsForSubscribe(
                eventType: .Resolve,
                namespace: "factory",
                correlationId: "request-42"
            ),
            "coaty/3/factory/RSV/+/request-42"
        )
        XCTAssertEqual(
            CommunicationTopic.createTopicStringByLevelsForSubscribe(eventType: .Discover),
            "coaty/3/+/DSC/+/+"
        )
    }

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
            XCTAssertThrowsError(try CommunicationTopic(topic), "Expected rejection of \(topic)")
        }
    }

    func testTopicValidationAndRawClassification() {
        XCTAssertTrue(CommunicationTopic.isValidPublicationTopic("sensors/temperature"))
        XCTAssertFalse(CommunicationTopic.isValidPublicationTopic("sensors/+"))
        XCTAssertFalse(CommunicationTopic.isValidPublicationTopic("sensors/#"))
        XCTAssertFalse(CommunicationTopic.isValidPublicationTopic(""))
        XCTAssertTrue(CommunicationTopic.isValidSubscriptionTopic("sensors/+/value"))
        XCTAssertFalse(CommunicationTopic.isValidSubscriptionTopic("bad\u{0000}topic"))
        XCTAssertFalse(CommunicationTopic.isRawTopic(topic: "coaty/3/ns/DAD/id"))
        XCTAssertTrue(CommunicationTopic.isRawTopic(topic: "application/events"))
    }

    func testMQTTWildcardMatching() {
        XCTAssertTrue(CommunicationTopic.matches("a/b/c", "a/+/c"))
        XCTAssertTrue(CommunicationTopic.matches("a/b/c/d", "a/b/#"))
        XCTAssertTrue(CommunicationTopic.matches("a//b", "a/+/b"))
        XCTAssertFalse(CommunicationTopic.matches("a/b/c/d", "a/+/c"))
        XCTAssertFalse(CommunicationTopic.matches("a/b", "a/b/c"))
        XCTAssertFalse(CommunicationTopic.matches("", "#"))
    }
}
