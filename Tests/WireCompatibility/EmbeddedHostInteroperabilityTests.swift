// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import Testing

@MainActor
struct EmbeddedHostInteroperabilityTests {
    private static let hostID = UUID16(parsing: "32400000-0000-4000-8000-000000000003")!
    private static let embeddedAgentID = UUID16(parsing: "32400000-0000-4000-8000-000000000001")!
    private static let embeddedRequesterID = UUID16(parsing: "32400000-0000-4000-8000-00000000000b")!
    private static let embeddedObjectID = "32400000-0000-4000-8000-000000000002"
    private static let correlationID = UUID16(parsing: "32400000-0000-4000-8000-000000000004")!
    private static let objectType = "coaty.test.Device"

    @Test(.enabled(if: embeddedHostDirectionIsEnabled("host-requester")))
    func hostDiscoversEmbeddedAgent() async throws {
        let environment = ProcessInfo.processInfo.environment
        let (runtime, advertiseStream, resolveStream, deadvertiseStream) = try makeRuntime(
            environment: environment,
            selectors: [
                .family(.advertise),
                .correlatedResponse(capability: .resolve, correlationID: Self.correlationID),
                .family(.deadvertise),
            ]
        )
        do {
            try await runtime.start()
            try signalEmbeddedHostReadiness(environment)

            var advertiseIterator = try #require(advertiseStream).makeAsyncIterator()
            let advertise = try await nextEmbeddedHostValue(
                &advertiseIterator,
                label: "embedded Advertise",
                runtime: runtime
            )
            try expectDevice(advertise.value, expectedID: Self.embeddedObjectID)
            #expect(advertise.context.sourceID == Self.embeddedAgentID)

            let receipt = await runtime.request(.discover(
                correlationID: Self.correlationID,
                payload: discoverPayload,
                timeoutMS: 60_000
            ))
            #expect(receipt == .accepted)

            var resolveIterator = try #require(resolveStream).makeAsyncIterator()
            let resolve = try await nextEmbeddedHostValue(
                &resolveIterator,
                label: "embedded Resolve",
                runtime: runtime
            )
            #expect(resolve.context.sourceID == Self.embeddedAgentID)
            #expect(resolve.context.correlationID == Self.correlationID)
            try expectDevice(resolve.value, expectedID: Self.embeddedObjectID)

            var deadvertiseIterator = try #require(deadvertiseStream).makeAsyncIterator()
            let deadvertise = try await nextEmbeddedHostValue(
                &deadvertiseIterator,
                label: "embedded Deadvertise",
                runtime: runtime
            )
            #expect(deadvertise.context.sourceID == Self.embeddedAgentID)
            try expectObjectIDs(deadvertise.value, containing: Self.embeddedObjectID)
            emitEmbeddedHostState("host-requester", sourceId: Self.embeddedAgentID)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test(.enabled(if: embeddedHostDirectionIsEnabled("host-responder")))
    func embeddedAgentDiscoversHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        let (runtime, discoverStream, _, _) = try makeRuntime(
            environment: environment,
            selectors: [.family(.discover)]
        )
        let advertiser = Task { [runtime] in
            while !Task.isCancelled {
                guard await runtime.publish(.advertise(devicePayload)) == .accepted else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        do {
            try await runtime.start()
            try signalEmbeddedHostReadiness(environment)

            var discoverIterator = try #require(discoverStream).makeAsyncIterator()
            let discover = try await nextEmbeddedHostValue(
                &discoverIterator,
                label: "embedded Discover",
                runtime: runtime
            )
            #expect(discover.context.sourceID == Self.embeddedRequesterID)
            #expect(discover.context.correlationID == Self.correlationID)
            let receipt = await runtime.respond(.resolve(
                correlationID: Self.correlationID,
                payload: devicePayload
            ))
            #expect(receipt == .accepted)
            #expect(await runtime.publish(.deadvertise(deadvertisePayload)) == .accepted)
            emitEmbeddedHostState("host-responder", sourceId: Self.embeddedRequesterID)
            advertiser.cancel()
            await advertiser.value
            await runtime.stop()
        } catch {
            advertiser.cancel()
            await advertiser.value
            await runtime.stop()
            throw error
        }
    }

    private func makeRuntime(
        environment: [String: String],
        selectors: [RuntimeEventSelector]
    ) throws -> (AxolotyRuntime, RuntimeEventStream?, RuntimeEventStream?, RuntimeEventStream?) {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "axoloty-embedded"
        let identity = try RuntimeIdentity(id: Self.hostID, name: "axoloty-embedded-host")
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: namespace)
        var streams = [RuntimeEventStream]()
        for selector in selectors {
            streams.append(try builder.events(
                matching: selector,
                buffering: RuntimeBufferingPolicy.failAfterDrop(capacity: 8)
            ))
        }
        let definition = try builder.finish()
        let binding = try MQTTBinding(configuration: try MQTTBindingConfiguration(host: host, port: port))
        return (
            AxolotyRuntime(definition: definition, transport: binding),
            streams.indices.contains(0) ? streams[0] : nil,
            streams.indices.contains(1) ? streams[1] : nil,
            streams.indices.contains(2) ? streams[2] : nil
        )
    }

    private var devicePayload: [UInt8] {
        Self.devicePayload
    }

    private static var devicePayload: [UInt8] {
        Array("{\"object\":{\"coreType\":\"CoatyObject\",\"objectType\":\"\(objectType)\",\"objectId\":\"\(embeddedObjectID)\",\"name\":\"ESP32-C6 A\"}}".utf8)
    }

    private var discoverPayload: [UInt8] {
        Array("{\"objectTypes\":[\"\(Self.objectType)\"]}".utf8)
    }

    private var deadvertisePayload: [UInt8] {
        Array("{\"objectIds\":[\"\(Self.embeddedObjectID)\"]}".utf8)
    }

    private func expectDevice(_ payload: [UInt8], expectedID: String) throws {
        let root = try #require(JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any])
        let object = try #require(root["object"] as? [String: Any])
        #expect(object["objectId"] as? String == expectedID)
        #expect(object["objectType"] as? String == Self.objectType)
    }

    private func expectObjectIDs(_ payload: [UInt8], containing expectedID: String) throws {
        let root = try #require(JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any])
        let objectIDs = try #require(root["objectIds"] as? [String])
        #expect(objectIDs.contains(expectedID))
    }
}

private func embeddedHostDirectionIsEnabled(_ direction: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["WIRE_EMBEDDED_HOST_LIVE"] == "1" &&
        environment["WIRE_EMBEDDED_HOST_DIRECTION"] == direction
}

private func nextEmbeddedHostValue(
    _ iterator: inout AsyncStream<RuntimeEventValue>.Iterator,
    label: String,
    runtime: AxolotyRuntime
) async throws -> RuntimeEventValue {
    do {
        return try await nextValue(&iterator, timeout: .seconds(60))
    } catch {
        let state = await runtime.state()
        let diagnostics = await runtime.diagnosticsSnapshot()
        throw AxolotyError.runtime(
            code: .timedOut,
            reason: "Timed out waiting for (label); state=\(state); diagnostics=\(diagnostics); cause=\(error)"
        )
    }
}

private func signalEmbeddedHostReadiness(_ environment: [String: String]) throws {
    guard let path = environment["WIRE_READY_FILE"] else { return }
    try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func emitEmbeddedHostState(_ direction: String, sourceId: UUID16) {
    let line = "{\"state\":\"passed\",\"direction\":\"\(direction)\",\"sourceId\":\"\(sourceId)\"}"
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
