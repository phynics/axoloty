// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("external routes accept bounded exact carrier-neutral keys")
    func externalRouteValidationAcceptsExactTopic() throws {
        let route = try ExternalIoRoute("plant/line-7/temperature")
        let sameRoute = try ExternalIoRoute("plant/line-7/temperature")
        #expect(route == sameRoute)
    }

    @Test("external routes accept characters restricted by the MQTT adapter")
    func externalRouteValidationAcceptsCarrierSpecificCharacters() throws {
        _ = try ExternalIoRoute("wild/+")
        _ = try ExternalIoRoute("wild/#")
        _ = try ExternalIoRoute("quoted/\"topic")
        _ = try ExternalIoRoute(#"backslash/\topic"#)
    }

    @Test("external routes fit three UUIDs plus application routing")
    func externalRouteValidationAcceptsThreeUUIDs() throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"
        let topic = "gnostic/1/workspaces/\(first)/agents/\(second)/tools/\(third)/requests"

        #expect(topic.utf8.count > 128)
        #expect(topic.utf8.count <= WireBufferConfig.maxTopicLength)
        _ = try ExternalIoRoute(topic)
    }

    @Test("external routes retain metadata without encoded-size inflation")
    func externalRouteMetadataUsesExactBytes() throws {
        let route = try ExternalIoRoute("plant/line-7/temperature")
        route.routeBytes.withBytes { bytes in
            #expect(bytes.equals("plant/line-7/temperature"))
        }
    }

    @Test("external routes reject controls, invalid levels, and overflow")
    func externalRouteValidationRejectsInvalidTopics() {
        for topic in [
            "", "/leading", "trailing/", "double//slash",
            "nul\0topic", "control/\ntopic", "del/\u{7F}", "c1/\u{0085}",
        ] {
            #expect(throws: AxolotyError.self) { _ = try ExternalIoRoute(topic) }
        }
        let bounded = try? ExternalIoRoute(
            String(repeating: "x", count: WireBufferConfig.maxTopicLength)
        )
        #expect(bounded != nil)
        #expect(throws: AxolotyError.self) {
            _ = try ExternalIoRoute(String(repeating: "x", count: WireBufferConfig.maxTopicLength + 1))
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
        let route = try ExternalIoRoute("coaty/3/route-profile/IOV/00000000-0000-4000-8000-0000000000d2")
        var rejected = false
        do {
            _ = try builder.ioSource(metadata: metadata, as: Bool.self, externalRoute: route)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }
}
