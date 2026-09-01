// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("external MQTT routes accept bounded exact topics")
    func externalRouteValidationAcceptsExactTopic() throws {
        let route = try MQTTExternalIoRoute("plant/line-7/temperature")
        let sameRoute = try MQTTExternalIoRoute("plant/line-7/temperature")
        #expect(route == sameRoute)
    }

    @Test("external MQTT routes fit three UUIDs plus application routing")
    func externalRouteValidationAcceptsThreeUUIDs() throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"
        let topic = "gnostic/1/workspaces/\(first)/agents/\(second)/tools/\(third)/requests"

        #expect(topic.utf8.count > 128)
        #expect(topic.utf8.count <= WireBufferConfig.maxTopicLength)
        _ = try MQTTExternalIoRoute(topic)
    }

    @Test("external MQTT routes retain metadata without encoded-size inflation")
    func externalRouteMetadataUsesExactBytes() throws {
        let route = try MQTTExternalIoRoute("plant/line-7/temperature")
        route.topicBytes.withBytes { bytes in
            #expect(bytes.equals("plant/line-7/temperature"))
        }
    }

    @Test("external MQTT routes reject unsafe metadata characters, invalid levels, and overflow")
    func externalRouteValidationRejectsInvalidTopics() {
        for topic in [
            "", "/leading", "trailing/", "double//slash", "wild/+", "wild/#",
            "nul\0topic", "quoted/\"topic", #"backslash/\topic"#, "control/\ntopic",
        ] {
            #expect(throws: AxolotyError.self) { _ = try MQTTExternalIoRoute(topic) }
        }
        let bounded = try? MQTTExternalIoRoute(
            String(repeating: "x", count: WireBufferConfig.maxTopicLength)
        )
        #expect(bounded != nil)
        #expect(throws: AxolotyError.self) {
            _ = try MQTTExternalIoRoute(String(repeating: "x", count: WireBufferConfig.maxTopicLength + 1))
        }
    }

    @Test("active profile namespace cannot be reused as an external route")
    func externalRouteValidationRejectsActiveProfile() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "route-profile")
        var builder = try RuntimeBuilder(identity: identity, namespace: "route-profile")
        let metadataJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-0000000000d1\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
        let metadata = try Object<IoSourceMetadata>(decoding: ByteSlice(
            bytes: metadataJSON.utf8Start,
            length: metadataJSON.utf8CodeUnitCount
        ))
        let route = try MQTTExternalIoRoute("coaty/3/route-profile/IOV/00000000-0000-4000-8000-0000000000d2")
        var rejected = false
        do {
            _ = try builder.ioSource(metadata: metadata, as: Bool.self, externalRoute: route)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test("MQTT topics preserve the complete UUID")
    func mqttUUIDFormattingPreservesAllBytes() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        #expect(MQTTBinding.uuidString(id) == "44444444-4444-4444-8444-444444444444")
    }

    @Test("identity startup advertisement uses the canonical core-type filter")
    func identityStartupTopicIsFiltered() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        #expect(MQTTBinding.topic(
            for: key,
            namespace: "test",
            eventTypeFilter: Array("Identity".utf8)
        ) == "coaty/3/test/ADV:Identity/44444444-4444-4444-8444-444444444444")
    }

    @Test("MQTT topics preserve object-type filter separators")
    func objectTypeFilterUsesDoubleColon() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        #expect(MQTTBinding.topic(
            for: key,
            namespace: "test",
            eventTypeFilter: Array("coaty.Identity".utf8),
            eventTypeFilterKind: .objectType
        ) == "coaty/3/test/ADV::coaty.Identity/44444444-4444-4444-8444-444444444444")
    }

    @Test("binding keeps every Coaty profile route out of external classification")
    func foreignCoatyProfileIsNotExternal() throws {
        let binding = try MQTTBinding(configuration: .init(host: "localhost", port: 1883))
        let route = Array("coaty/3/other-namespace/IOV/00000000-0000-4000-8000-000000000001".utf8)
        let classification = route.withUnsafeBufferPointer { buffer in
            let slice = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return binding.classifyRoute(slice)
        }
        #expect(classification == .unrelated)
    }
}
