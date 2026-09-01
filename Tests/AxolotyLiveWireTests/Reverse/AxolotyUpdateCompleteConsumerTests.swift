// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Responds to a CoatyJS Update with a correlated modern Complete.
@MainActor
struct AxolotyUpdateCompleteConsumerTests {
    @Test(.enabled(if: scenarioIsEnabled))
    func decodesUpdateAndPublishesCorrelatedComplete() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try RuntimeBuilder(
            identity: ModernConsumerSupport.identity(name: "axoloty-modern-update-responder"),
            namespace: ModernConsumerSupport.namespace(environment: environment)
        )
        let stream = try builder.events(matching: .family(.update), buffering: .failAfterDrop(capacity: 4))
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "Update")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            let object = try #require(root["object"] as? [String: Any])
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(object["coreType"] as? String == "CoatyObject")
            #expect(object["objectType"] as? String == ModernConsumerSupport.fixtureType)
            #expect(object["objectId"] as? String == ModernConsumerSupport.fixtureID)
            #expect(object["name"] as? String == "wire-fixture")
            let correlationID = try #require(event.context.correlationID)
            let payload = Array(#"{"object":{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture-completed"},"privateData":{"reference":"axoloty-modern"}}"#.utf8)
            #expect(await runtime.respond(.complete(correlationID: correlationID, payload: payload)) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"update-complete\",\"response\":\"complete\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}

private let scenarioIsEnabled =
    ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1" &&
    ProcessInfo.processInfo.environment["WIRE_SCENARIO"] == "update-complete"
