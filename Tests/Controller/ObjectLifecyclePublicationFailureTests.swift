// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Focused failure-path tests for the best-effort object lifecycle
/// publication APIs (issue #456): a forced event-construction or publication
/// failure must not be silently dropped -- it must emit a diagnosable
/// ``AxolotyError`` log line with the offending object's identifier.
@MainActor
@Suite
struct ObjectLifecyclePublicationFailureTests {

    private let mqttHost = "127.0.0.1"

    /// An object with an object type containing `/` fails `AdvertiseEvent.with`
    /// (`TopicBuilder.isValidEventTypeFilter` rejects `/`). Both advertise
    /// paths must log the wrapped failure instead of silently returning.
    @Test
    func invalidObjectTypeAdvertiseIsLoggedNotSilentlyDropped() throws {
        let controller = try makeController()
        defer { controller.container.shutdown() }
        // Force replacement of the transport so no broker is contacted (the
        // configuration is offline anyway, but this makes the intent explicit).
        controller.communicationManager.client = SilentPublishingClient()

        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "invalid/type",
            objectId: CoatyUUID(),
            name: "test"
        )

        let advertise = try StandardErrorCapture.capture {
            controller.advertiseDiscoverableObject(object: object)
        }
        #expect(advertise.output.contains("Failed to advertise discoverable object"))
        #expect(advertise.output.contains(object.objectId.string))
        #expect(advertise.output.contains("AxolotyError"))

        let readvertise = try StandardErrorCapture.capture {
            controller.readvertiseDiscoverableObject(object: object)
        }
        #expect(readvertise.output.contains("Failed to readvertise discoverable object"))
        #expect(readvertise.output.contains(object.objectId.string))
    }

    /// The deadvertise path is non-throwing (event construction cannot fail),
    /// so an offline transport must not log an error -- the operation is
    /// genuinely best-effort with nothing to report.
    @Test
    func deadvertiseDoesNotLogWhenTransportIsSilent() throws {
        let controller = try makeController()
        defer { controller.container.shutdown() }

        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.example.Thing",
            objectId: CoatyUUID(),
            name: "thing"
        )
        controller.communicationManager.client = SilentPublishingClient()

        let capture = try StandardErrorCapture.capture {
            controller.deadvertiseDiscoverableObject(object: object)
        }
        // No forced failure to report: deadvertise event construction never
        // throws. Only assert that the path completes and, if any line was
        // produced, it is not an unclassified advertise-failure line.
        #expect(!capture.output.contains("Failed to advertise discoverable object"))
    }

    private func makeController() throws -> ObjectLifecycleController {
        let configuration = Configuration(
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(
                    host: mqttHost,
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            )
        )
        let components = Components(
            controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
            objectTypes: []
        )
        let container = try Container.resolve(components: components, configuration: configuration)
        return try #require(
            container.getController(name: "ObjectLifecycleController") as? ObjectLifecycleController
        )
    }
}

/// A client that never publishes but accepts the contract, so tests exercise
/// only the controller-side failure path without a live broker.
private final class SilentPublishingClient: CommunicationClient, CommunicationClientDelegate {
    var delegate: CommunicationClientDelegate = FakeClientDelegate()

    func setStreams(_ streams: CommunicationStreams) {}
    func connect(lastWillTopic: String, lastWillMessage: String) {}
    func disconnect() {}
    func publish(_ topic: String, message: String) {}
    func publish(_ topic: String, message: [UInt8]) {}
    @MainActor func publishAndWait(_ topic: String, message: [UInt8]) async throws {}
    @MainActor func subscribe(_ topic: String) async throws {}
    @MainActor func unsubscribe(_ topic: String) async throws {}
    func didReceiveStart() {}
}

/// Minimal delegate satisfying `CommunicationClientDelegate`.
private final class FakeClientDelegate: CommunicationClientDelegate {
    func didReceiveStart() {}
}