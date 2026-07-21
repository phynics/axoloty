// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Verifies the CoatyJS Call -> modern Swift Return direction.
@MainActor
struct AxolotyCallReturnConsumerTests {
    @Test(.enabled(if: callReturnConsumerIsEnabled))
    func decodesCallAndPublishesCorrelatedReturn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeCallReturnConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let stream = try await manager.communication.observeCallStream(operation: "wire-fixture-operation")
        var iterator = stream.makeAsyncIterator()
        try signalCallReturnReadiness(environment: environment)

        let call = try await nextCallReturnValue(&iterator)
        #expect(call.sourceId == "22222222-2222-4222-8222-222222222222")
        #expect(call.operation == "wire-fixture-operation")
        let parameters = try #require(call.parameters)
        let decoded = try JSONDecoder().decode(CallParameters.self, from: Data(parameters.utf8))
        #expect(decoded.operand == 7)
        #expect(decoded.reference == "coatyjs-2.4.0")

        let correlationId = try #require(call.correlationId)
        manager.communication.publishReturn(
            event: ReturnEvent.with(
                result: "{\"answer\":49,\"objectId\":\"11111111-1111-4111-8111-111111111111\"}",
                executionInfo: "{\"executor\":\"axoloty-modern\"}"
            ),
            correlationId: correlationId
        )
        emitCallReturnState("{\"state\":\"ack\",\"scenario\":\"call-return\",\"response\":\"return\"}")
    }
}

private struct CallParameters: Decodable {
    let operand: Int
    let reference: String
}

private let callReturnConsumerIsEnabled =
    ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1" &&
    ProcessInfo.processInfo.environment["WIRE_SCENARIO"] == "call-return"

@MainActor
private func makeCallReturnConsumerManager(environment: [String: String]) throws ->
    (container: Container, communication: CommunicationManager)
{
    let container = Container.resolve(
        components: Components(controllers: [:], objectTypes: []),
        configuration: Configuration(
            common: CommonOptions(agentIdentity: [
                "name": "axoloty-modern-call-responder",
                "objectId": CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            ]),
            communication: CommunicationOptions(
                namespace: environment["WIRE_NAMESPACE"] ?? "wire-compat-v1",
                mqttClientOptions: MQTTClientOptions(
                    host: environment["WIRE_BROKER_HOST"] ?? "127.0.0.1",
                    port: UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
                ),
                shouldAutoStart: false
            )
        )
    )
    guard let communication = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "container did not resolve a communication manager")
    }
    return (container, communication)
}

private func nextCallReturnValue(
    _ iterator: inout AsyncStream<CallEventSnapshot>.Iterator
) async throws -> CallEventSnapshot {
    do {
        return try await nextValue(&iterator, timeout: .seconds(120))
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "Call stream ended before CoatyJS published")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS Call")
    }
}

private func signalCallReturnReadiness(environment: [String: String]) throws {
    guard let path = environment["WIRE_READY_FILE"] else { return }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func emitCallReturnState(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
