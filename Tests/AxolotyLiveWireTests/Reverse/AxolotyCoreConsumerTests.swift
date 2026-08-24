// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Decodes CoatyJS one-way core events through the modern runtime boundary.
@MainActor
struct AxolotyCoreConsumerTests {
    @Test(.enabled(if: scenarioIsEnabled("deadvertise")))
    func decodesDeadvertiseFromCoatyJS() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try makeBuilder(environment: environment, name: "axoloty-core-consumer")
        let stream = try builder.events(matching: .family(.deadvertise), buffering: .failAfterDrop(capacity: 4))
        let runtime = try makeRuntime(builder: &builder, environment: environment)
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "deadvertise")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(root["objectIds"] as? [String] == [ModernConsumerSupport.fixtureID])
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"deadvertise\",\"objectId\":\"\(ModernConsumerSupport.fixtureID)\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test(.enabled(if: scenarioIsEnabled("channel")))
    func decodesChannelFromCoatyJS() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try makeBuilder(environment: environment, name: "axoloty-core-consumer")
        let stream = try builder.events(matching: .channel(identifier: "wire-fixture-channel"), buffering: .failAfterDrop(capacity: 4))
        let runtime = try makeRuntime(builder: &builder, environment: environment)
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "channel")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            let object = try #require(root["object"] as? [String: Any])
            let privateData = try #require(root["privateData"] as? [String: Any])
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(object["coreType"] as? String == "CoatyObject")
            #expect(object["objectType"] as? String == ModernConsumerSupport.fixtureType)
            #expect(object["objectId"] as? String == ModernConsumerSupport.fixtureID)
            #expect(object["name"] as? String == "wire-fixture")
            #expect(privateData["sequence"] as? Int == 7)
            #expect(privateData["reference"] as? String == "coatyjs-2.4.0")
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"channel\",\"objectId\":\"\(ModernConsumerSupport.fixtureID)\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func makeBuilder(environment: [String: String], name: String) throws -> RuntimeDefinition.Builder {
        try RuntimeDefinition.Builder(
            identity: ModernConsumerSupport.identity(name: name),
            namespace: ModernConsumerSupport.namespace(environment: environment)
        )
    }

    private func makeRuntime(builder: inout RuntimeDefinition.Builder, environment: [String: String]) throws -> AxolotyRuntime {
        AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
    }
}

private func scenarioIsEnabled(_ scenario: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["WIRE_JS_TO_MODERN_LIVE"] == "1" && environment["WIRE_SCENARIO"] == scenario
}
