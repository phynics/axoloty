// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

struct WireCaptureFixtureTests {
    @Test
    func reportsFixtureRecordAndFieldForMalformedJSON() {
        do {
            _ = try WireCaptureFixture(name: "broken", text: "not-json")
            Issue.record("expected malformed fixture error")
        } catch {
            #expect(error.localizedDescription.contains("fixture broken, record 1, field record"))
        }
    }

    @Test
    func reportsPayloadFieldForMalformedBase64() throws {
        let fixture = try WireCaptureFixture(
            name: "broken-payload",
            text: #"{"format":"coaty-wire-capture/v1","producer":{"implementation":"test","version":"1"},"scenario":"test","sequence":7,"capturedAt":"now","mqtt":{"topic":"coaty/3/test/DSC/source/correlation","qos":0,"retain":false},"payload":{"encoding":"base64","bytes":"%%%"},"normalizationProfile":"coaty-v1"}"#
        )
        do {
            _ = try fixture.payloadText(fixture.records[0])
            Issue.record("expected malformed payload error")
        } catch {
            #expect(error.localizedDescription.contains("fixture broken-payload, record 7, field payload.bytes"))
        }
    }

    @Test
    func reportsTopicFieldForMalformedCorrelation() throws {
        let fixture = try WireCaptureFixture(
            name: "broken-topic",
            text: #"{"format":"coaty-wire-capture/v1","producer":{"implementation":"test","version":"1"},"scenario":"test","sequence":3,"capturedAt":"now","mqtt":{"topic":"coaty/3/test/DSC/source","qos":0,"retain":false},"payload":{"encoding":"base64","bytes":"e30="},"normalizationProfile":"coaty-v1"}"#
        )
        do {
            _ = try fixture.correlatedTopic(fixture.records[0], namespace: "test", eventLevel: "DSC")
            Issue.record("expected malformed topic error")
        } catch {
            #expect(error.localizedDescription.contains("fixture broken-topic, record 3, field mqtt.topic"))
        }
    }
}
