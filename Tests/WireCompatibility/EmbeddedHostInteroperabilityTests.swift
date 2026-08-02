// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing
import AxolotyWire

@MainActor
struct EmbeddedHostInteroperabilityTests {
    @Test(.enabled(if: embeddedHostDirectionIsEnabled("host-requester")))
    func hostDiscoversEmbeddedAgent() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeEmbeddedHostManager(environment)
        defer { manager.container.shutdown() }
        try await manager.container.startAndWaitUntilReady()

        let advertises = try await manager.communication.observeAdvertiseStream(withObjectType: deviceObject.objectType)
        let deadvertises = await manager.communication.observeDeadvertiseStream()
        var advertiseIterator = advertises.makeAsyncIterator()
        var deadvertiseIterator = deadvertises.makeAsyncIterator()
        try signalEmbeddedHostReadiness(environment)

        let advertise = try await nextEmbeddedHostValue(&advertiseIterator, label: "embedded Advertise")
        #expect(advertise.sourceId == embeddedAgentId)
        #expect(advertise.object.objectId == embeddedObjectId)
        #expect(advertise.object.objectType == deviceObject.objectType)

        let responses = await manager.communication.publishDiscover(
            DiscoverEvent.with(objectTypes: [deviceObject.objectType])
        )
        var responseIterator = responses.makeAsyncIterator()
        let response = try await nextEmbeddedHostValue(&responseIterator, label: "embedded Resolve")
        #expect(response.eventType == WireEventType.resolve.rawValue)
        #expect(response.sourceId == embeddedAgentId)
        #expect(response.correlationId != nil)
        let resolve = try #require(response.decodePayload(ResolveEvent.self))
        #expect(resolve.data.object?.objectId.string == embeddedObjectId)

        let deadvertise = try await nextEmbeddedHostValue(&deadvertiseIterator, label: "embedded Deadvertise")
        #expect(deadvertise.sourceId == embeddedAgentId)
        #expect(deadvertise.objectIds == [embeddedObjectId])
        emitEmbeddedHostState("host-requester", sourceId: embeddedAgentId)
    }

    @Test(.enabled(if: embeddedHostDirectionIsEnabled("host-responder")))
    func embeddedAgentDiscoversHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manager = try makeEmbeddedHostManager(environment)
        defer { manager.container.shutdown() }
        try await manager.container.startAndWaitUntilReady()

        let discovers = await manager.communication.observeDiscoverStream()
        var discoverIterator = discovers.makeAsyncIterator()
        try signalEmbeddedHostReadiness(environment)
        let advertiser = Task { @MainActor in
            while !Task.isCancelled {
                try? manager.communication.publishAdvertise(AdvertiseEvent.with(object: deviceObject))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { advertiser.cancel() }

        let discover = try await nextEmbeddedHostValue(&discoverIterator, label: "embedded Discover")
        #expect(discover.sourceId == embeddedRequesterId)
        #expect(discover.objectTypes == [deviceObject.objectType])
        let correlationId = try #require(discover.correlationId)
        #expect(correlationId == embeddedCorrelationId)
        manager.communication.publishResolve(
            event: ResolveEvent.with(object: deviceObject),
            correlationId: correlationId
        )
        try await Task.sleep(for: .milliseconds(500))
        manager.communication.publishDeadvertise(DeadvertiseEvent.with(objectIds: [deviceObject.objectId]))
        emitEmbeddedHostState("host-responder", sourceId: embeddedRequesterId)
    }
}

private let embeddedAgentId = "32400000-0000-4000-8000-000000000001"
private let embeddedRequesterId = "32400000-0000-4000-8000-00000000000b"
private let embeddedObjectId = "32400000-0000-4000-8000-000000000002"
private let embeddedCorrelationId = "32400000-0000-4000-8000-000000000004"

private var deviceObject: CoatyObject {
    CoatyObject(
        coreType: .CoatyObject,
        objectType: "coaty.test.Device",
        objectId: CoatyUUID(uuidString: embeddedObjectId)!,
        name: "ESP32-C6 A"
    )
}

private func embeddedHostDirectionIsEnabled(_ direction: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["WIRE_EMBEDDED_HOST_LIVE"] == "1" &&
        environment["WIRE_EMBEDDED_HOST_DIRECTION"] == direction
}

@MainActor
private func makeEmbeddedHostManager(
    _ environment: [String: String]
) throws -> (container: Container, communication: CommunicationManager) {
    let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
    let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
    let identity = CoatyUUID(uuidString: "32400000-0000-4000-8000-000000000003")!
    let container = try Container.resolve(
        components: Components(controllers: [:], objectTypes: []),
        configuration: Configuration(
            common: CommonOptions(agentIdentity: ["name": "axoloty-host", "objectId": identity]),
            communication: CommunicationOptions(
                namespace: "axoloty-embedded",
                mqttClientOptions: MQTTClientOptions(host: host, port: port),
                shouldAutoStart: false
            )
        )
    )
    guard let communication = container.communicationManager else {
        throw AxolotyError.invalidConfiguration(
            option: "communicationManager",
            reason: "container did not resolve a communication manager"
        )
    }
    return (container, communication)
}

private func nextEmbeddedHostValue<Element: Sendable>(
    _ iterator: inout AsyncStream<Element>.Iterator,
    label: String
) async throws -> Element {
    do {
        return try await nextValue(&iterator, timeout: .seconds(60))
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for \(label)")
    }
}

private func signalEmbeddedHostReadiness(_ environment: [String: String]) throws {
    guard let path = environment["WIRE_READY_FILE"] else { return }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func emitEmbeddedHostState(_ direction: String, sourceId: String) {
    let line = "{\"state\":\"passed\",\"direction\":\"\(direction)\",\"sourceId\":\"\(sourceId)\"}"
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
