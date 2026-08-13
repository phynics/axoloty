// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

@MainActor
@Suite
struct SensorSourcePublicationTests {
    @Test
    func successfulPublicationInvokesDidPublishAfterTransportCompletion() async throws {
        let gate = PublicationGate()
        let controller = try makeController(io: MockSensorIo(parameters: nil))
        defer { controller.container.shutdown() }
        let transport = PublicationTransport { _ in await gate.wait() }
        try await install(transport, on: controller)

        let publication = Task {
            try await controller.publishChanneledObservationAndWait(sensorId: controller.sensor.objectId)
        }
        try await waitUntil("transport publication started") { await gate.started }
        #expect(controller.lifecycle == [.will])

        await gate.release()
        try await publication.value
        #expect(controller.lifecycle == [.will, .did])
        #expect(controller.lastObservationResult == "0")
    }

    @Test
    func failedTransportPublicationSuppressesDidPublishAndWrapsError() async throws {
        let controller = try makeController(io: MockSensorIo(parameters: nil))
        defer { controller.container.shutdown() }
        let transport = PublicationTransport { _ in throw TestTransportError() }
        try await install(transport, on: controller)

        do {
            try await controller.publishChanneledObservationAndWait(sensorId: controller.sensor.objectId)
            Issue.record("Expected publication to fail")
        } catch let error as AxolotyError {
            guard case let .caught(cause) = error else {
                Issue.record("Expected a caught publication error, got \(error)")
                return
            }
            #expect(cause is TestTransportError)
        }

        #expect(controller.lifecycle == [.will])
    }

    @Test
    func multipleSensorReadCallbacksUseFirstValueOnly() async throws {
        let controller = try makeController(io: MultiReadSensorIo(parameters: nil))
        defer { controller.container.shutdown() }
        let transport = PublicationTransport()
        try await install(transport, on: controller)

        try await controller.publishChanneledObservationAndWait(sensorId: controller.sensor.objectId)

        #expect(controller.lifecycle == [.will, .did])
        #expect(transport.publicationCount == 1)
        #expect(controller.lastObservationResult == "1")
    }

    private func makeController(io: SensorIo) throws -> RecordingSensorSourceController {
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
            io: io,
            observationPublicationType: .none,
            samplingInterval: nil
        )
        return controller
    }

    private func install(
        _ transport: PublicationTransport,
        on controller: RecordingSensorSourceController
    ) async throws {
        transport.delegate = controller.communicationManager
        transport.setStreams(controller.communicationManager.streams)
        controller.communicationManager.client = transport
        transport.delegate.didUpdateCommunicationState(.online)
        try await waitUntil("communication manager online") {
            controller.communicationManager.communicationState == .online
        }
    }
}

@MainActor
private final class RecordingSensorSourceController: SensorSourceController {
    enum Lifecycle: Equatable {
        case will
        case did
    }

    let sensor: Sensor
    var lifecycle: [Lifecycle] = []
    var lastObservationResult: String?

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

    override func onObservationWillPublish(container: SensorContainer, observation: Observation) {
        lifecycle.append(.will)
        lastObservationResult = observation.result
    }

    override func onObservationDidPublish(container: SensorContainer, observation: Observation) {
        lifecycle.append(.did)
    }
}

private final class PublicationTransport: CommunicationClient {
    var delegate: CommunicationClientDelegate
    private var streams: CommunicationStreams?
    private let completion: @Sendable ([UInt8]) async throws -> Void
    private(set) var publicationCount = 0

    init(
        delegate: CommunicationClientDelegate = NoopCommunicationDelegate(),
        completion: @escaping @Sendable ([UInt8]) async throws -> Void = { _ in }
    ) {
        self.delegate = delegate
        self.completion = completion
    }

    func setStreams(_ streams: CommunicationStreams) {
        self.streams = streams
    }

    func connect(lastWillTopic _: String, lastWillMessage _: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}

    @MainActor func publishAndWait(_ topic: String, message: [UInt8]) async throws {
        publicationCount += 1
        try await completion(message)
    }

    @MainActor func subscribe(_ topic: String) async throws {}
    @MainActor func unsubscribe(_ topic: String) async throws {}
}

private struct NoopCommunicationDelegate: CommunicationClientDelegate {
    func didReceiveStart() {}
}

private struct TestTransportError: Error, Sendable {}

private final class MultiReadSensorIo: SensorIo {
    override func read(callback: ((Any) -> Void)) {
        callback(1)
        callback(2)
    }
}

private actor PublicationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0 ..< 100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AxolotyError.runtime(code: .timedOut, reason: description)
}
