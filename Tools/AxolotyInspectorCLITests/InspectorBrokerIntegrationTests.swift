// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

/// Broker-backed integration tests for the inspector.
///
/// Disabled by default. Enable by setting `AXOLOTY_INSPECTOR_LIVE=1` and
/// ensuring a Mosquitto broker is reachable at the configured host/port.
@MainActor
@Suite(.serialized)
struct InspectorBrokerIntegrationTests {

    private func brokerHost() -> String {
        ProcessInfo.processInfo.environment["AXOLOTY_MQTT_HOST"] ?? "127.0.0.1"
    }

    private func brokerPort() -> UInt16 {
        UInt16(ProcessInfo.processInfo.environment["AXOLOTY_MQTT_PORT"] ?? "1883") ?? 1883
    }

    private func makeProducer(namespace: String) async throws -> Container {
        let container = try Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                communication: CommunicationOptions(
                    namespace: namespace,
                    mqttClientOptions: MQTTClientOptions(
                        host: brokerHost(),
                        port: brokerPort(),
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                )
            )
        )
        try await container.startAndWaitUntilReady()
        return container
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AXOLOTY_INSPECTOR_LIVE"] == "1"))
    func catalogObservesAdvertiseAndDeadvertise() async throws {
        let namespace = "inspector-test-\(UUID().uuidString.prefix(8))"
        let host = brokerHost()
        let port = brokerPort()

        let producer = try await makeProducer(namespace: namespace)
        defer { producer.shutdown() }

        let session = try AxolotyInspectorSession(configuration: InspectorConnectionConfiguration(
            host: host, port: port, namespace: namespace,
            connectTimeout: .seconds(5)
        ))

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        let app = InspectorApplication(
            configuration: InspectorConfiguration(
                command: .catalog(CatalogCommand(
                    duration: InspectorDuration(value: .seconds(3))
                )),
                connection: InspectorConnectionConfiguration(
                    host: host, port: port, namespace: namespace
                ),
                output: .ndjson
            ),
            session: session,
            writeOutput: { outputContinuation.yield($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let runTask = _Concurrency.Task {
            let result = await app.run()
            outputContinuation.finish()
            return result
        }
        defer { outputContinuation.finish() }
        var outputIterator = outputStream.makeAsyncIterator()

        let sessionStarted = try #require(await outputIterator.next())
        #expect(sessionStarted.contains("\"kind\":\"session-started\""))

        let objectId = CoatyUUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let object = CoatyObject(
            coreType: .Identity,
            objectType: "coaty.object.Identity",
            objectId: objectId,
            name: "Test Agent"
        )
        let cm = producer.communicationManager!
        cm.publishAdvertise(try AdvertiseEvent.with(object: object))

        var matchedAdvertise: String?
        while let line = await outputIterator.next() {
            if line.contains("\"objectId\":\"\(objectId.string)\"") {
                matchedAdvertise = line
                break
            }
        }
        let advertise = try #require(matchedAdvertise)
        #expect(advertise.contains("\"kind\":\"advertise\""))
        #expect(advertise.contains("\"name\":\"Test Agent\""))

        cm.publishDeadvertise(DeadvertiseEvent.with(objectIds: [objectId]))

        var matchedDeadvertise: String?
        while let line = await outputIterator.next() {
            if line.contains("\"kind\":\"deadvertise\"") {
                matchedDeadvertise = line
                break
            }
        }
        let deadvertise = try #require(matchedDeadvertise)
        #expect(deadvertise.contains("\"kind\":\"deadvertise\""))
        #expect(await runTask.value == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AXOLOTY_INSPECTOR_LIVE"] == "1"))
    func catalogObservesCustomObjectType() async throws {
        let namespace = "inspector-custom-\(UUID().uuidString.prefix(8))"
        let host = brokerHost()
        let port = brokerPort()

        let producer = try await makeProducer(namespace: namespace)
        defer { producer.shutdown() }

        let session = try AxolotyInspectorSession(configuration: InspectorConnectionConfiguration(
            host: host, port: port, namespace: namespace,
            connectTimeout: .seconds(5)
        ))

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        let app = InspectorApplication(
            configuration: InspectorConfiguration(
                command: .catalog(CatalogCommand(
                    duration: InspectorDuration(value: .seconds(3))
                )),
                connection: InspectorConnectionConfiguration(
                    host: host, port: port, namespace: namespace
                ),
                output: .ndjson
            ),
            session: session,
            writeOutput: { outputContinuation.yield($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let runTask = _Concurrency.Task {
            let result = await app.run()
            outputContinuation.finish()
            return result
        }
        defer { outputContinuation.finish() }
        var outputIterator = outputStream.makeAsyncIterator()

        let sessionStarted = try #require(await outputIterator.next())
        #expect(sessionStarted.contains("\"kind\":\"session-started\""))

        let objectId = CoatyUUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let customObject = CoatyObject(
            coreType: .Identity,
            objectType: "com.example.CustomAgent",
            objectId: objectId,
            name: "Custom Sensor"
        )
        let cm = producer.communicationManager!
        cm.publishAdvertise(try AdvertiseEvent.with(object: customObject))

        var matchedAdvertise: String?
        while let line = await outputIterator.next() {
            if line.contains("\"objectId\":\"\(objectId.string)\"") {
                matchedAdvertise = line
                break
            }
        }
        let advertise = try #require(matchedAdvertise)
        #expect(advertise.contains("\"kind\":\"advertise\""))
        #expect(advertise.contains("\"objectType\":\"com.example.CustomAgent\""))
        #expect(await runTask.value == nil)
    }
}
