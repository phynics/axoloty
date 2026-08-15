// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Focused lifecycle coverage for the shared Discover/Query responder tasks
/// owned by ``SensorSourceController``.
///
/// The responder tasks are started lazily by the first sensor registration and
/// serve every currently registered sensor. They were previously retained for
/// the whole controller lifetime after their final registration was removed,
/// extending the controller's lifetime and keeping stale stream subscriptions
/// alive. Removing the final registration must cancel and release them, while
/// unregistering a non-final sensor must leave them active for the registrations
/// that remain.
@MainActor
@Suite
struct SensorSourceResponderReleaseTests {

    @Test
    func respondersStartOnFirstRegistrationAndReleaseOnFinalUnregister() async throws {
        let container = try makeContainer()
        defer { container.shutdown() }
        let controller = try #require(
            container.getController(name: "sensor-source") as? SensorSourceController
        )

        // No registration yet: no responder tasks are running.
        #expect(!controller.hasActiveResponders)

        let first = makeSensor()
        let second = makeSensor()

        // The first registration starts both shared responder tasks.
        try controller.registerSensor(
            sensor: first,
            io: MockSensorIo(parameters: nil),
            observationPublicationType: .none,
            samplingInterval: nil
        )
        #expect(controller.hasActiveResponders)

        // An additional registration leaves them running (still shared).
        try controller.registerSensor(
            sensor: second,
            io: MockSensorIo(parameters: nil),
            observationPublicationType: .none,
            samplingInterval: nil
        )
        #expect(controller.hasActiveResponders)

        // Removing a non-final registration must NOT release the shared
        // responder tasks: sensors remain registered for the rest of the
        // controller's lifetime.
        try controller.unregisterSensor(sensorId: first.objectId)
        #expect(controller.hasActiveResponders)

        // Removing the final registration cancels and releases them.
        try controller.unregisterSensor(sensorId: second.objectId)
        #expect(!controller.hasActiveResponders)
    }

    @Test
    func reRegisteringStartsRespondersAgainAfterRelease() async throws {
        let container = try makeContainer()
        defer { container.shutdown() }
        let controller = try #require(
            container.getController(name: "sensor-source") as? SensorSourceController
        )

        let first = makeSensor()
        try controller.registerSensor(
            sensor: first,
            io: MockSensorIo(parameters: nil),
            observationPublicationType: .none,
            samplingInterval: nil
        )
        try controller.unregisterSensor(sensorId: first.objectId)
        #expect(!controller.hasActiveResponders)

        // A later registration lazily restarts the shared responders.
        let second = makeSensor()
        try controller.registerSensor(
            sensor: second,
            io: MockSensorIo(parameters: nil),
            observationPublicationType: .none,
            samplingInterval: nil
        )
        #expect(controller.hasActiveResponders)
        try controller.unregisterSensor(sensorId: second.objectId)
        #expect(!controller.hasActiveResponders)
    }

    /// A controller whose final registration was unregistered can be fully
    /// deallocated: the released responder tasks no longer retain it.
    @Test
    func controllerDeallocatesAfterFinalUnregister() async throws {
        weak var weakController: SensorSourceController?
        var container: Container?

        do {
            let resolved = try makeContainer()
            let controller = try #require(
                resolved.getController(name: "sensor-source") as? SensorSourceController
            )
            weakController = controller

            let sensor = makeSensor()
            try controller.registerSensor(
                sensor: sensor,
                io: MockSensorIo(parameters: nil),
                observationPublicationType: .none,
                samplingInterval: nil
            )
            #expect(controller.hasActiveResponders)

            // Final unregister releases the responder tasks. Asserting the
            // task edge is cleared is not enough for the lazy @MainActor tasks
            // to have observed their cancellation, so the deallocation is
            // awaited below.
            try controller.unregisterSensor(sensorId: sensor.objectId)
            #expect(!controller.hasActiveResponders)

            container = resolved
        }

        container?.shutdown()
        container = nil

        // Once the cancelled responder tasks unwind they must drop the strong
        // reference to the controller, letting it deallocate. A retained
        // responder task would keep this weak reference alive indefinitely.
        // Poll directly (this test body is already MainActor) rather than
        // through a @Sendable closure that would not be able to capture the
        // non-Sendable weak reference.
        for _ in 0 ..< 200 {
            if weakController == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakController == nil)
    }

    private func makeContainer() throws -> Container {
        let options = ControllerOptions(extra: [
            "skipSensorAdvertise": true,
            "skipSensorDeadvertise": true,
        ])
        return try Container.resolve(
            components: Components(
                controllers: ["sensor-source": SensorSourceController.self],
                objectTypes: []
            ),
            configuration: Configuration(
                communication: CommunicationOptions(
                    namespace: "sensor-source-responder-release-regression",
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
    }

    private func makeSensor() -> Sensor {
        Sensor(
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
    }
}