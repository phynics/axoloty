// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// Responds to CoatyJS Discover and Query requests through the modern runtime.
@MainActor
struct AxolotyCoreRequestConsumerTests {
    @Test(.enabled(if: scenarioIsEnabled("discover-resolve")))
    func respondsToCoatyJSDiscover() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try makeBuilder(environment: environment)
        let stream = try builder.events(matching: .family(.discover), buffering: .failAfterDrop(capacity: 4))
        let runtime = try makeRuntime(builder: &builder, environment: environment)
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "Discover")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(root["objectTypes"] as? [String] == [ModernConsumerSupport.fixtureType])
            let correlationID = try #require(event.context.correlationID)
            let payload = Array(#"{"object":{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture"},"privateData":{"reference":"coatyswift-modern"}}"#.utf8)
            #expect(await runtime.respond(.resolve(correlationID: correlationID, payload: payload)) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"discover-resolve\",\"correlationId\":\"\(correlationID)\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test(.enabled(if: scenarioIsEnabled("query-retrieve")))
    func respondsToCoatyJSQuery() async throws {
        let environment = ModernConsumerSupport.environment()
        var builder = try makeBuilder(environment: environment)
        let stream = try builder.events(matching: .family(.query), buffering: .failAfterDrop(capacity: 4))
        let runtime = try makeRuntime(builder: &builder, environment: environment)
        do {
            try await runtime.start()
            try ModernConsumerSupport.signalReadiness(environment: environment)
            let event = try await ModernConsumerSupport.next(from: stream, timeout: .seconds(120), scenario: "Query")
            let root = try ModernConsumerSupport.jsonObject(event.value)
            #expect(event.context.sourceID == ModernConsumerSupport.requesterID)
            #expect(root["objectTypes"] as? [String] == [ModernConsumerSupport.fixtureType])
            #expect((root["objectFilter"] as? [String: Any])?.isEmpty == true)
            let correlationID = try #require(event.context.correlationID)
            let payload = Array(#"{"objects":[{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture"}],"privateData":{"reference":"coatyswift-modern","resultSet":"deterministic"}}"#.utf8)
            #expect(await runtime.respond(.retrieve(correlationID: correlationID, payload: payload)) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"query-retrieve\",\"correlationId\":\"\(correlationID)\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func makeBuilder(environment: [String: String]) throws -> RuntimeBuilder {
        try RuntimeBuilder(
            identity: ModernConsumerSupport.identity(name: "axoloty-core-request-consumer"),
            namespace: ModernConsumerSupport.namespace(environment: environment)
        )
    }

    private func makeRuntime(builder: inout RuntimeBuilder, environment: [String: String]) throws -> AxolotyRuntime {
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
