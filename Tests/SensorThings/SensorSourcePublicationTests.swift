// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@MainActor
@Suite
struct SensorSourcePublicationTests {
    @Test
    func successfulPublicationInvokesCallbacksInOrder() throws {
        let controller = try makeController(channelId: "sensor-channel")
        defer { controller.container.shutdown() }

        controller.publishChanneledObservation(sensorId: controller.sensor.objectId)

        #expect(controller.lifecycle == [.will, .did])
    }

    @Test
    func failedPublicationDoesNotInvokeDidPublish() throws {
        let controller = try makeController(channelId: "")
        defer { controller.container.shutdown() }

        controller.publishChanneledObservation(sensorId: controller.sensor.objectId)

        #expect(controller.lifecycle == [.will])
    }

    private func makeController(channelId: String) throws -> RecordingSensorSourceController {
        let options = ControllerOptions(extra: [
            "skipSensorAdvertise": true,
            "skipSensorDeadvertise": true,
        ])
        let container = try Container.resolve(
            components: Components(
                controllers: ["sensor-source": RecordingSensorSourceController.self],
                objectTypes: []
            ),
            configuration: Configuration(
                communication: CommunicationOptions(
                    namespace: "sensor-source-publication-regression",
                    mqttClientOptions: MQTTClientOptions(
                        host: "127.0.0.1",
                        port: 1883,
                        shouldTryMDNSDiscovery: false,
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                ),
                controllers: ControllerConfig(
                    controllerOptions: ["sensor-source": options]
                )
            )
        )
        let controller = try #require(
            container.getController(name: "sensor-source") as? RecordingSensorSourceController
        )
        try controller.registerSensor(
            sensor: controller.sensor,
            io: MockSensorIo(parameters: nil),
            observationPublicationType: .none,
            samplingInterval: nil
        )
        controller.channelId = channelId
        return controller
    }
}

@MainActor
private final class RecordingSensorSourceController: SensorSourceController {
    enum Lifecycle: Equatable {
        case will
        case did
    }

    let sensor: Sensor
    var channelId = "sensor-channel"
    var lifecycle: [Lifecycle] = []

    required init(container: Container, options: ControllerOptions?, controllerType: String) {
        self.sensor = Sensor(
            description: "test",
            encodingType: SensorEncodingTypes.UNDEFINED,
            metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(
                name: "Celsius",
                symbol: "degC",
                definition: "http://www.qudt.org"
            ),
            observationType: ObservationTypes.MEASUREMENT,
            phenomenonTime: nil,
            resultTime: nil,
            observedProperty: ObservedProperty(
                name: "Temperature",
                definition: "http://dbpedia.org/page/Dew_point",
                description: "DewPoint Temperature"
            ),
            name: "Thermometer",
            objectId: .init(),
            parentObjectId: nil
        )
        super.init(container: container, options: options, controllerType: controllerType)
    }

    override func getChannelId(container: SensorContainer) -> String {
        channelId
    }

    override func onObservationWillPublish(container: SensorContainer, observation: Observation) {
        lifecycle.append(.will)
    }

    override func onObservationDidPublish(container: SensorContainer, observation: Observation) {
        lifecycle.append(.did)
    }
}
