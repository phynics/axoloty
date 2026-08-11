// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@MainActor
@Suite
struct SensorSourceQueryTypeTests {
    @Test
    func sensorObjectTypeSelectorIsAccepted() {
        let request = QueryEventSnapshot(
            objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR]
        )

        #expect(SensorSourceController.querySelectsSensor(request))
    }

    @Test
    func coatyObjectCoreTypeSelectorIsAccepted() {
        let request = QueryEventSnapshot(coreTypes: [.CoatyObject])

        #expect(SensorSourceController.querySelectsSensor(request))
    }

    @Test
    func thingObjectTypeSelectorIsRejected() {
        let request = QueryEventSnapshot(
            objectTypes: [SensorThingsTypes.OBJECT_TYPE_THING]
        )

        #expect(!SensorSourceController.querySelectsSensor(request))
    }

    @Test
    func unrelatedCoreTypeSelectorIsRejected() {
        let request = QueryEventSnapshot(coreTypes: [.Location])

        #expect(!SensorSourceController.querySelectsSensor(request))
    }

    @Test
    func missingOrConflictingSelectorsAreRejected() {
        let missingSelector = QueryEventSnapshot()
        let conflictingSelectors = QueryEventSnapshot(
            objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR],
            coreTypes: [.Location]
        )

        #expect(!SensorSourceController.querySelectsSensor(missingSelector))
        #expect(!SensorSourceController.querySelectsSensor(conflictingSelectors))
    }

    @Test
    func compatibleQueriesPublishRetrieveResponsesOnly() async throws {
        let sensor = try #require(
            SensorThingsCollection.getObjectByType(
                objectType: SensorThingsTypes.OBJECT_TYPE_SENSOR,
                uuid: .init()
            ) as? Sensor
        )
        let sensorDefinition = SensorDefinition(
            sensor: sensor,
            io: MockSensorIo.self,
            observationPublicationType: .none
        )
        let sourceOptions = ControllerOptions(extra: [
            "sensors": [sensorDefinition],
            "skipSensorAdvertise": true,
            "skipSensorDeadvertise": true,
        ])
        let communicationOptions = CommunicationOptions(
            namespace: "sensor-query-type-regression",
            mqttClientOptions: MQTTClientOptions(
                host: "127.0.0.1",
                port: 1883,
                shouldTryMDNSDiscovery: false,
                autoReconnect: false
            ),
            shouldAutoStart: false
        )
        let sourceContainer = try Container.resolve(
            components: Components(
                controllers: ["sensor-source": SensorSourceController.self],
                objectTypes: []
            ),
            configuration: Configuration(
                communication: communicationOptions,
                controllers: ControllerConfig(controllerOptions: ["sensor-source": sourceOptions])
            )
        )
        let receiverContainer = try Container.resolve(
            components: Components(
                controllers: ["query-receiver": MockReceiverController.self],
                objectTypes: []
            ),
            configuration: Configuration(
                communication: CommunicationOptions(
                    namespace: "sensor-query-type-regression",
                    mqttClientOptions: MQTTClientOptions(
                        host: "127.0.0.1",
                        port: 1883,
                        shouldTryMDNSDiscovery: false,
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                )
            )
        )
        defer {
            sourceContainer.shutdown()
            receiverContainer.shutdown()
        }

        try await withTimeout("sensor source container ready") {
            try await sourceContainer.startAndWaitUntilReady()
        }
        try await withTimeout("query receiver container ready") {
            try await receiverContainer.startAndWaitUntilReady()
        }
        let receiver = try #require(
            receiverContainer.getController(name: "query-receiver") as? MockReceiverController
        )

        for objectType in [SensorThingsTypes.OBJECT_TYPE_THING] {
            let responses = await receiver.communicationManager.publishQuery(
                QueryEvent.with(objectTypes: [objectType])
            )
            await expectNoRetrieveResponse(from: responses)
        }

        let locationResponses = await receiver.communicationManager.publishQuery(
            QueryEvent.with(coreTypes: [.Location])
        )
        await expectNoRetrieveResponse(from: locationResponses)

        let sensorResponses = await receiver.communicationManager.publishQuery(
            QueryEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_SENSOR])
        )
        let sensorRetrieve = try await nextRetrieveResponse(from: sensorResponses)
        #expect(sensorRetrieve.data.objects.map(\.objectId) == [sensor.objectId])

        let coatyObjectResponses = await receiver.communicationManager.publishQuery(
            QueryEvent.with(coreTypes: [.CoatyObject])
        )
        let coatyObjectRetrieve = try await nextRetrieveResponse(from: coatyObjectResponses)
        #expect(coatyObjectRetrieve.data.objects.map(\.objectId) == [sensor.objectId])
    }
}

@MainActor
private func nextRetrieveResponse(
    from responses: AsyncStream<ResponseEventSnapshot>
) async throws -> RetrieveEvent {
    var iterator = responses.makeAsyncIterator()
    let response = try await nextValue(&iterator, timeout: .seconds(2))
    #expect(response.eventType == "RTV")
    return try #require(response.decodePayload(RetrieveEvent.self))
}

@MainActor
private func expectNoRetrieveResponse(
    from responses: AsyncStream<ResponseEventSnapshot>
) async {
    var iterator = responses.makeAsyncIterator()
    let response: ResponseEventSnapshot? = try? await nextValue(
        &iterator,
        timeout: .milliseconds(500)
    )
    #expect(response == nil)
}
