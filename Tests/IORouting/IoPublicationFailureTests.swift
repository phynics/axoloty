// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Focused failure-path tests for the best-effort IO publication APIs
/// (issue #456): IO-context publication, IO-node advertisement, and
/// value publication failures must log a diagnosable ``AxolotyError`` chain
/// instead of being silently discarded.
@MainActor
@Suite
struct IoPublicationFailureTests {

    /// A value for a raw-only IO source published with a JSON payload fails
    /// `IoValueEvent.with`, and the wrapped failure must be logged rather than
    /// silently swallowed.
    @Test
    func ioValueConstructionFailureIsLoggedNotSilent() throws {
        let controller = try makeIoSourceController()
        defer { controller.container.shutdown() }

        let source = IoSource(valueType: "Temperature", useRawIoValues: true)
        // The source is associated so the value is eligible for publication;
        // the JSON payload conflicts with the raw-only source, so event
        // construction throws.
        controller.sourceItems[source.objectId] = (source, true, nil)

        let capture = try StandardErrorCapture.capture {
            controller.publish(source: source, value: 42.0)
        }
        #expect(capture.output.contains("Failed to construct IoValue event"))
        #expect(capture.output.contains(source.objectId.string))
        #expect(capture.output.contains("AxolotyError"))
    }

    /// A value publish constructs a valid event for a source (association is
    /// gated authoritatively by ``CommunicationManager``'s IO registry via
    /// ``publishIoValue``, not by a controller-local flag). The construction
    /// path must not drop a well-formed value before it is handed to the
    /// communication manager.
    @Test
    func publishForwardsValidEventToCommunicationManager() throws {
        let controller = try makeIoSourceController()
        defer { controller.container.shutdown() }

        let source = IoSource(valueType: "Temperature", useRawIoValues: false)
        // A valid JSON value constructs an event successfully; it is handed to
        // `publishIoValue`, which self-gates on the registry route.
        let capture = try StandardErrorCapture.capture {
            controller.publish(source: source, value: 42.0)
        }
        #expect(!capture.output.contains("Failed to construct IoValue event"))
    }

    /// An IO context with an invalid object type fails `AdvertiseEvent.with`
    /// while the router registers itself on manager start; the wrapped failure
    /// must be logged.
    @Test
    func ioContextPublishFailureOnRouterStartIsLogged() throws {
        let router = try makeRouter()
        router.ioContext.objectType = "bad/type"

        let capture = try StandardErrorCapture.capture {
            router.onCommunicationManagerStarting()
        }
        #expect(capture.output.contains("Failed to publish IO context after router start"))
        #expect(capture.output.contains(router.ioContext.objectId.string))
        #expect(capture.output.contains("AxolotyError"))
    }

    private func makeIoSourceController() throws -> IoSourceController {
        let container = try minimalContainer(withController: "IoSourceController")
        return try #require(container.getController(name: "IoSourceController") as? IoSourceController)
    }

    private func makeRouter() throws -> RuleBasedIoRouter {
        let ioContext = IoContext(
            coreType: .IoContext,
            objectType: "test",
            objectId: CoatyUUID(),
            name: "test"
        )
        let container = try minimalContainer()
        let router = RuleBasedIoRouter(
            container: container,
            options: ControllerOptions(extra: ["ioContext": ioContext]),
            controllerType: "test"
        )
        router.onInit()
        return router
    }

    private func minimalContainer(withController name: String = "") throws -> Container {
        var controllers: [String: Controller.Type] = [:]
        if !name.isEmpty {
            controllers[name] = IoSourceController.self
        }
        let configuration = Configuration(
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(
                    host: "127.0.0.1",
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            )
        )
        return try Container.resolve(
            components: Components(controllers: controllers, objectTypes: []),
            configuration: configuration
        )
    }
}