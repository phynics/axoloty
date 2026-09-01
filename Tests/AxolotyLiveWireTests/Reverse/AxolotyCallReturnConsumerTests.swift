// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Responds to a CoatyJS Call with a correlated modern Return.
@MainActor
struct AxolotyCallReturnConsumerTests {
    @Test(.enabled(if: scenarioIsEnabled))
    func decodesCallAndPublishesCorrelatedReturn() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try RuntimeBuilder(
            identity: ModernConsumerSupport.identity(name: "axoloty-modern-call-responder"),
            namespace: ModernConsumerSupport.namespace(environment: environment)
        )
        let stream = try builder.events(matching: .family(.call), buffering: .failAfterDrop(capacity: 4))
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "Call")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            let parameters = try #require(root["parameters"] as? [String: Any])
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(parameters["operand"] as? Int == 7)
            #expect(parameters["reference"] as? String == "coatyjs-2.4.0")
            let correlationID = try #require(event.context.correlationID)
            let payload = Array(#"{"result":{"answer":49,"objectId":"11111111-1111-4111-8111-111111111111"},"executionInfo":{"executor":"axoloty-modern"}}"#.utf8)
            #expect(await runtime.respond(.returnEvent(correlationID: correlationID, payload: payload)) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"call-return\",\"response\":\"return\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}

private let scenarioIsEnabled =
    ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1" &&
    ProcessInfo.processInfo.environment["WIRE_SCENARIO"] == "call-return"
