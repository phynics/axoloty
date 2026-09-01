// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Decodes a CoatyJS Advertise event through the modern runtime boundary.
@MainActor
struct AxolotyAdvertiseConsumerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1"))
    func decodesAdvertiseFromCoatyJS() async throws {
        let environment = ModernConsumerSupport.environment()
        let identity = try ModernConsumerSupport.identity(name: "axoloty-advertise-consumer")
        var builder = try RuntimeBuilder(
            identity: identity,
            namespace: ModernConsumerSupport.namespace(environment: environment)
        )
        let stream = try builder.events(
            matching: .advertise(objectType: ModernConsumerSupport.fixtureType),
            buffering: .failAfterDrop(capacity: 4)
        )
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            ModernConsumerSupport.emit("{\"state\":\"ready\",\"scenario\":\"coatyjs-advertise\"}")

            let event = try await ModernConsumerSupport.next(
                from: stream,
                timeout: .seconds(120),
                scenario: "Advertise"
            )
            let root = try ModernConsumerSupport.jsonObject(event.value)
            let object = try #require(root["object"] as? [String: Any])
            #expect(object["coreType"] as? String == "CoatyObject")
            #expect(object["objectType"] as? String == ModernConsumerSupport.fixtureType)
            #expect(object["objectId"] as? String == ModernConsumerSupport.fixtureID)
            #expect(object["name"] as? String == "wire-fixture")
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"coatyjs-advertise\",\"objectId\":\"\(ModernConsumerSupport.fixtureID)\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}
