// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Handles request/response scenarios initiated by pinned CoatyJS.
@MainActor
struct AxolotyCoreRequestConsumerTests {
    @Test(.enabled(if: coreRequestConsumerScenarioIsEnabled("discover-resolve")))
    func respondsToCoatyJSDiscover() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeCoreRequestConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let stream = await manager.communication.observeDiscoverStream()
        var iterator = stream.makeAsyncIterator()
        try signalCoreRequestConsumerReadiness(environment: environment)

        let request = try await nextCoreRequestConsumerValue(
            &iterator,
            timeout: .seconds(120),
            scenario: "discover-resolve"
        )
        #expect(request.sourceId == "22222222-2222-4222-8222-222222222222")
        #expect(request.objectTypes == ["com.coaty.test.WireFixture"])
        let correlationId = try #require(request.correlationId)

        manager.communication.publishResolve(
            event: ResolveEvent.with(
                object: makeFixtureObject(),
                privateData: ["reference": "coatyswift-modern"]
            ),
            correlationId: correlationId
        )
        emitCoreRequestConsumerState("{\"state\":\"ack\",\"scenario\":\"discover-resolve\",\"correlationId\":\"\(correlationId)\"}")
    }

    @Test(.enabled(if: coreRequestConsumerScenarioIsEnabled("query-retrieve")))
    func respondsToCoatyJSQuery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeCoreRequestConsumerManager(environment: environment)
        defer { manager.container.shutdown() }

        try await manager.container.startAndWaitUntilReady()
        let stream = await manager.communication.observeQueryStream()
        var iterator = stream.makeAsyncIterator()
        try signalCoreRequestConsumerReadiness(environment: environment)

        let request = try await nextCoreRequestConsumerValue(
            &iterator,
            timeout: .seconds(120),
            scenario: "query-retrieve"
        )
        #expect(request.sourceId == "22222222-2222-4222-8222-222222222222")
        #expect(request.objectTypes == ["com.coaty.test.WireFixture"])
        #expect(request.objectFilter == "{}")
        let correlationId = try #require(request.correlationId)

        manager.communication.publishRetrieve(
            event: RetrieveEvent.with(
                objects: [makeFixtureObject()],
                privateData: [
                    "reference": "coatyswift-modern",
                    "resultSet": "deterministic",
                ]
            ),
            correlationId: correlationId
        )
        emitCoreRequestConsumerState("{\"state\":\"ack\",\"scenario\":\"query-retrieve\",\"correlationId\":\"\(correlationId)\"}")
    }
}

private func makeFixtureObject() -> CoatyObject {
    CoatyObject(
        coreType: .CoatyObject,
        objectType: "com.coaty.test.WireFixture",
        objectId: CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        name: "wire-fixture"
    )
}

private func coreRequestConsumerScenarioIsEnabled(_ scenario: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["WIRE_JS_TO_MODERN_LIVE"] == "1" && environment["WIRE_SCENARIO"] == scenario
}

@MainActor
private func makeCoreRequestConsumerManager(environment: [String: String]) throws -> (container: Container, communication: CommunicationManager) {
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

private func nextCoreRequestConsumerValue<E: Sendable>(
    _ iterator: inout AsyncStream<E>.Iterator,
    timeout: Duration,
    scenario: String
) async throws -> E {
    do {
        return try await nextValue(&iterator, timeout: timeout)
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "\(scenario) stream ended before a request arrived")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS to publish \(scenario)")
    }
}

private func signalCoreRequestConsumerReadiness(environment: [String: String]) throws {
    guard let readyFile = environment["WIRE_READY_FILE"] else { return }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic)
}

private func emitCoreRequestConsumerState(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
