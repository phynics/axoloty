// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire
import Foundation
import Testing

@MainActor
struct AxolotyCoreProducerTests {
    private static let sourceID = UUID16(parsing: "22222222-2222-4222-8222-222222222222")!
    private static let fixtureID = "11111111-1111-4111-8111-111111111111"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1"))
    func publishesCoreEventsForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = try #require(environment["WIRE_SCENARIO"])
        let correlation = correlationID(for: scenario, ordinal: 0)
        let responseSelector = responseSelector(for: scenario, correlationID: correlation)
        let (runtime, responseStream) = try makeRuntime(
            environment: environment,
            responseSelector: responseSelector
        )
        do {
            try await runtime.start()
            try await run(
                scenario: scenario,
                correlation: correlation,
                responseStream: responseStream,
                runtime: runtime
            )
            ModernConsumerSupport.emit(
                "{\"state\":\"awaiting-peer-ack\",\"phase\":\"peer-ack\",\"scenario\":\"\(scenario)\",\"correlationId\":\"\(correlation)\"}"
            )
            try await ModernConsumerSupport.awaitPeerAcknowledgement(
                environment: environment,
                scenario: scenario,
                context: "correlationId=\(correlation)",
                timeout: .seconds(60)
            )
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func run(
        scenario: String,
        correlation: UUID16,
        responseStream: RuntimeEventStream?,
        runtime: AxolotyRuntime
    ) async throws {
        switch scenario {
        case "deadvertise":
            #expect(await runtime.publish(.advertise(fixturePayload)) == .accepted)
            #expect(await runtime.publish(.deadvertise(deadvertisePayload)) == .accepted)
        case "channel":
            #expect(await runtime.publish(.channel(
                identifier: "wire-fixture-channel",
                payload: channelPayload
            )) == .accepted)
        case "discover-resolve":
            #expect(await runtime.request(.discover(
                correlationID: correlation,
                payload: discoverPayload,
                timeoutMS: 5_000
            )) == .accepted)
            let response = try await requireResponse(responseStream)
            try expectObject(response.value, expectedName: "wire-fixture")
        case "query-retrieve":
            #expect(await runtime.request(.query(
                correlationID: correlation,
                payload: queryPayload(operand: "wire-fixture"),
                timeoutMS: 5_000
            )) == .accepted)
            let response = try await requireResponse(responseStream)
            try expectFirstObject(response.value, expectedName: "wire-fixture")
            _ = await runtime.cancel(correlationID: correlation)
        case "query-retrieve-filter-negative":
            #expect(await runtime.request(.query(
                correlationID: correlation,
                payload: queryPayload(operand: "no-match"),
                timeoutMS: 5_000
            )) == .accepted)
            try await expectNoResponse(responseStream)
            _ = await runtime.cancel(correlationID: correlation)
        case "query-retrieve-filter-operands":
            let operands = ["42", "42.5", "true", "null"]
            for (index, operand) in operands.enumerated() {
                let id = correlationID(for: scenario, ordinal: index)
                #expect(await runtime.request(.query(
                    correlationID: id,
                    payload: queryPayload(rawOperand: operand),
                    timeoutMS: 5_000
                )) == .accepted)
            }
            try await expectNoResponse(responseStream)
        case "update-complete":
            #expect(await runtime.request(.update(
                correlationID: correlation,
                payload: fixturePayload,
                timeoutMS: 5_000
            )) == .accepted)
            let response = try await requireResponse(responseStream)
            try expectObject(response.value, expectedName: "wire-fixture-completed")
        case "call-return":
            #expect(await runtime.request(.call(
                correlationID: correlation,
                operation: "wire-fixture-operation",
                payload: Array(#"{"parameters":{"operand":7}}"#.utf8),
                timeoutMS: 5_000
            )) == .accepted)
            let response = try await requireResponse(responseStream)
            try expectReturn(response.value)
        default:
            Issue.record("Unsupported core wire scenario: \(scenario)")
        }
    }

    private func makeRuntime(
        environment: [String: String],
        responseSelector: RuntimeEventSelector?
    ) throws -> (AxolotyRuntime, RuntimeEventStream?) {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let identity = try RuntimeIdentity(id: Self.sourceID, name: "axoloty-core-producer")
        var builder = try RuntimeBuilder(identity: identity, namespace: namespace)
        let stream = try responseSelector.map {
            try builder.events(
                matching: $0,
                buffering: .failAfterDrop(capacity: 4)
            )
        }
        let definition = try builder.finish()
        let binding = try MQTTBinding(configuration: try MQTTBindingConfiguration(host: host, port: port))
        return (AxolotyRuntime(definition: definition, transport: binding), stream)
    }

    private func responseSelector(for scenario: String, correlationID: UUID16) -> RuntimeEventSelector? {
        switch scenario {
        case "discover-resolve":
            return .correlatedResponse(capability: .resolve, correlationID: correlationID)
        case "query-retrieve", "query-retrieve-filter-negative":
            return .correlatedResponse(capability: .retrieve, correlationID: correlationID)
        case "query-retrieve-filter-operands":
            return .family(.retrieve)
        case "update-complete":
            return .correlatedResponse(capability: .complete, correlationID: correlationID)
        case "call-return":
            return .correlatedResponse(capability: .returnEvent, correlationID: correlationID)
        default: return nil
        }
    }

    private var fixturePayload: [UInt8] {
        Array(#"{"object":{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture"}}"#.utf8)
    }

    private var deadvertisePayload: [UInt8] {
        Array("{\"objectIds\":[\"\(Self.fixtureID)\"]}".utf8)
    }

    private var channelPayload: [UInt8] {
        Array(#"{"object":{"coreType":"CoatyObject","objectType":"com.coaty.test.WireFixture","objectId":"11111111-1111-4111-8111-111111111111","name":"wire-fixture"},"privateData":{"sequence":7}}"#.utf8)
    }

    private var discoverPayload: [UInt8] {
        Array(#"{"objectTypes":["com.coaty.test.WireFixture"]}"#.utf8)
    }

    private func queryPayload(operand: String) -> [UInt8] {
        queryPayload(rawOperand: "\"\(operand)\"")
    }

    private func queryPayload(rawOperand: String) -> [UInt8] {
        Array(#"{"objectTypes":["com.coaty.test.WireFixture"],"objectFilter":{"conditions":["name",[7,\#(rawOperand)]]}}"#.utf8)
    }

    private func correlationID(for scenario: String, ordinal: Int) -> UUID16 {
        let scenarios = [
            "deadvertise", "channel", "discover-resolve", "query-retrieve",
            "query-retrieve-filter-negative", "query-retrieve-filter-operands",
            "update-complete", "call-return",
        ]
        let scenarioIndex = scenarios.firstIndex(of: scenario) ?? 0
        let suffix = String(format: "%012x", (scenarioIndex * 16) + ordinal + 1)
        return UUID16(parsing: "55555555-5555-4555-8555-\(suffix)")!
    }

    private func requireResponse(_ stream: RuntimeEventStream?) async throws -> RuntimeEventValue {
        return try await ModernConsumerSupport.next(
            from: try #require(stream),
            timeout: .seconds(5),
            scenario: "Axoloty core response"
        )
    }

    private func expectNoResponse(_ stream: RuntimeEventStream?) async throws {
        var iterator = try #require(stream).makeAsyncIterator()
        do {
            let value = try await nextValue(&iterator, timeout: .seconds(3))
            Issue.record("received unexpected response: \(value)")
        } catch is AsyncWaitTimeoutError {
            return
        } catch {
            throw error
        }
    }

    private func expectObject(_ payload: [UInt8], expectedName: String) throws {
        let root = try #require(try jsonObject(payload) as? [String: Any])
        let object = try #require(root["object"] as? [String: Any])
        #expect(object["objectId"] as? String == Self.fixtureID)
        #expect(object["name"] as? String == expectedName)
    }

    private func expectFirstObject(_ payload: [UInt8], expectedName: String) throws {
        let root = try #require(try jsonObject(payload) as? [String: Any])
        let objects = try #require(root["objects"] as? [[String: Any]])
        let object = try #require(objects.first)
        #expect(object["objectId"] as? String == Self.fixtureID)
        #expect(object["name"] as? String == expectedName)
    }

    private func expectReturn(_ payload: [UInt8]) throws {
        let root = try #require(try jsonObject(payload) as? [String: Any])
        let result = try #require(root["result"] as? [String: Any])
        #expect(result["answer"] as? Int == 49)
        #expect(result["objectId"] as? String == Self.fixtureID)
    }

    private func jsonObject(_ payload: [UInt8]) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(payload))
    }
}
