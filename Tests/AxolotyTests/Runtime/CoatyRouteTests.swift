// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyProtocol
import AxolotyWire

/// Coaty route synthesis, which the runtime performs before handing a
/// transport a finished message.
///
/// These assertions lived against `MQTTBinding.topic` while the adapter built
/// its own routes. The layout they pin is defined by `coaty/3`, not by MQTT.
@Suite("Coaty route synthesis")
struct CoatyRouteTests {
    @Test("Coaty routes preserve the complete UUID")
    func mqttUUIDFormattingPreservesAllBytes() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        #expect(CoatyRoute.uuidString(id) == "44444444-4444-4444-8444-444444444444")
    }

    @Test("identity startup advertisement uses the canonical core-type filter")
    func identityStartupTopicIsFiltered() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        #expect(try CoatyRoute.route(
            for: key,
            namespace: "test",
            eventTypeFilter: Array("Identity".utf8)
        ) == "coaty/3/test/ADV:Identity/44444444-4444-4444-8444-444444444444")
    }

    @Test("Coaty routes preserve object-type filter separators")
    func objectTypeFilterUsesDoubleColon() throws {
        let id = try #require(UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
        let key = try ProtocolRoutingKey(capability: .advertise, sourceID: id)
        #expect(try CoatyRoute.route(
            for: key,
            namespace: "test",
            eventTypeFilter: Array("coaty.Identity".utf8),
            eventTypeFilterKind: .objectType
        ) == "coaty/3/test/ADV::coaty.Identity/44444444-4444-4444-8444-444444444444")
    }
}
