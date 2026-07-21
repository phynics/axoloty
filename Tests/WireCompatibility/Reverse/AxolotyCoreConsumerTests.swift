// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Testing

/// The JS -> modern direction of the one-way core capabilities: pinned
/// CoatyJS 2.4.0 publishes while Axoloty decodes and validates each event.
@MainActor
struct AxolotyCoreConsumerTests {
    @Test(.enabled(if: coreConsumerScenarioIsEnabled("deadvertise")))
    func decodesDeadvertiseFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeCoreConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let stream = await manager.communication.observeDeadvertiseStream()
        var iterator = stream.makeAsyncIterator()
        try signalCoreConsumerReadiness(environment: environment)

        let snapshot = try await nextCoreConsumerValue(
            &iterator,
            timeout: .seconds(120),
            scenario: "deadvertise"
        )
        #expect(snapshot.sourceId == "22222222-2222-4222-8222-222222222222")
        #expect(snapshot.objectIds == ["11111111-1111-4111-8111-111111111111"])

        emitCoreConsumerState("{\"state\":\"ack\",\"scenario\":\"deadvertise\",\"objectId\":\"11111111-1111-4111-8111-111111111111\"}")
    }

    @Test(.enabled(if: coreConsumerScenarioIsEnabled("channel")))
    func decodesChannelFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeCoreConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let stream = try await manager.communication.observeChannelStream(channelId: "wire-fixture-channel")
        var iterator = stream.makeAsyncIterator()
        try signalCoreConsumerReadiness(environment: environment)

        let snapshot = try await nextCoreConsumerValue(
            &iterator,
            timeout: .seconds(120),
            scenario: "channel"
        )
        let object = try #require(snapshot.object)
        let privateData = try #require(snapshot.privateData)
        let decodedPrivateData = try JSONDecoder().decode(ChannelPrivateData.self, from: Data(privateData.utf8))
        #expect(snapshot.sourceId == "22222222-2222-4222-8222-222222222222")
        #expect(snapshot.channelId == "wire-fixture-channel")
        #expect(snapshot.eventTypeFilter == "wire-fixture-channel")
        #expect(object.coreType == .CoatyObject)
        #expect(object.objectType == "com.coaty.test.WireFixture")
        #expect(object.objectId == "11111111-1111-4111-8111-111111111111")
        #expect(object.name == "wire-fixture")
        #expect(decodedPrivateData.sequence == 7)
        #expect(decodedPrivateData.reference == "coatyjs-2.4.0")

        emitCoreConsumerState("{\"state\":\"ack\",\"scenario\":\"channel\",\"objectId\":\"11111111-1111-4111-8111-111111111111\"}")
    }
}

private struct ChannelPrivateData: Decodable {
    let sequence: Int
    let reference: String
}

private func coreConsumerScenarioIsEnabled(_ scenario: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["WIRE_JS_TO_MODERN_LIVE"] == "1" && environment["WIRE_SCENARIO"] == scenario
}

@MainActor
private func makeCoreConsumerManager(environment: [String: String]) throws -> (container: Container, communication: CommunicationManager) {
    let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
    let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
    let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
    let container = Container.resolve(
        components: Components(controllers: [:], objectTypes: []),
        configuration: Configuration(communication: CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        ))
    )
    guard let communication = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "container did not resolve a communication manager")
    }
    return (container, communication)
}

private func nextCoreConsumerValue<E: Sendable>(
    _ iterator: inout AsyncStream<E>.Iterator,
    timeout: Duration,
    scenario: String
) async throws -> E {
    do {
        return try await nextValue(&iterator, timeout: timeout)
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "\(scenario) stream ended before a snapshot arrived")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS to publish \(scenario)")
    }
}

private func signalCoreConsumerReadiness(environment: [String: String]) throws {
    guard let readyFile = environment["WIRE_READY_FILE"] else {
        return
    }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic)
}

private func emitCoreConsumerState(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
