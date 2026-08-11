// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

/// Regression tests for the atomic ``Container.resolve(components:configuration:)``
/// bootstrap contract introduced in #282: the public factory either returns a
/// fully initialized container or throws a structured ``AxolotyError`` — never
/// a partially constructed container with a fallback identity or nil
/// communication manager.
@MainActor
@Suite
struct ContainerBootstrapTests {

    // MARK: - Malformed agent identity

    /// A malformed `agentIdentity.name` (non-String) must surface as an
    /// actionable ``AxolotyError/invalidConfiguration(option:reason:)`` from
    /// `Container.resolve`, not be swallowed into the fallback
    /// `Identity(name: "Coaty Agent")`.
    @Test
    func malformedAgentIdentityThrowsInsteadOfFallingBack() {
        let configuration = Configuration(
            common: CommonOptions(agentIdentity: [
                "name": 12345,
            ]),
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(),
                shouldAutoStart: false
            )
        )
        let components = Components(controllers: [:], objectTypes: [])

        do {
            _ = try Container.resolve(components: components, configuration: configuration)
            Issue.record("Expected Container.resolve to throw for a malformed agent identity")
        } catch let error as AxolotyError {
            guard case .invalidConfiguration = error else {
                Issue.record("Expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(error.userFriendlyMessage == "agentIdentity.name: must be a String")
        } catch {
            Issue.record("Expected AxolotyError, got \(error)")
        }
    }

    /// Every supplied optional agent-identity field is type-checked rather
    /// than silently coerced to `nil` at the legacy `[String: Any]` boundary.
    @Test
    func malformedOptionalAgentIdentityFieldsThrow() {
        let cases: [(key: String, value: Any, message: String)] = [
            ("externalId", 12345, "agentIdentity.externalId: must be a String"),
            ("parentObjectId", "not-a-coaty-uuid", "agentIdentity.parentObjectId: must be a CoatyUUID"),
            ("locationId", "not-a-coaty-uuid", "agentIdentity.locationId: must be a CoatyUUID"),
            ("isDeactivated", "false", "agentIdentity.isDeactivated: must be a Bool"),
        ]

        for testCase in cases {
            let configuration = Configuration(
                common: CommonOptions(agentIdentity: [testCase.key: testCase.value]),
                communication: CommunicationOptions(
                    mqttClientOptions: MQTTClientOptions(),
                    shouldAutoStart: false
                )
            )
            let components = Components(controllers: [:], objectTypes: [])

            do {
                _ = try Container.resolve(components: components, configuration: configuration)
                Issue.record("Expected Container.resolve to throw for malformed agentIdentity.\(testCase.key)")
            } catch let error as AxolotyError {
                guard case .invalidConfiguration = error else {
                    Issue.record("Expected .invalidConfiguration, got \(error)")
                    continue
                }
                #expect(error.userFriendlyMessage == testCase.message)
            } catch {
                Issue.record("Expected AxolotyError, got \(error)")
            }
        }
    }

    // MARK: - Missing MQTT client options

    /// Missing `mqttClientOptions` must throw from bootstrap, not defer the
    /// failure to a later `registerController` or `startAndWaitUntilReady`
    /// call against a partially constructed container.
    @Test
    func missingMqttClientOptionsThrowsFromBootstrap() {
        let configuration = Configuration(
            communication: CommunicationOptions(shouldAutoStart: false)
        )
        let components = Components(controllers: [:], objectTypes: [])

        do {
            _ = try Container.resolve(components: components, configuration: configuration)
            Issue.record("Expected Container.resolve to throw when mqttClientOptions is missing")
        } catch let error as AxolotyError {
            guard case .invalidConfiguration = error else {
                Issue.record("Expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(error.userFriendlyMessage == "mqttClientOptions: must be set when using the default MQTT transport")
        } catch {
            Issue.record("Expected AxolotyError, got \(error)")
        }
    }

    // MARK: - Valid bootstrap

    /// A valid bootstrap must return a container whose identity, runtime, and
    /// communication manager are all non-nil — proving the atomic path does not
    /// regress the happy path.
    @Test
    func validBootstrapResolvesAllComponents() throws {
        let configuration = Configuration(
            common: CommonOptions(agentIdentity: [
                "name": "test-agent",
            ]),
            communication: CommunicationOptions(
                mqttClientOptions: MQTTClientOptions(),
                shouldAutoStart: false
            )
        )
        let components = Components(controllers: [:], objectTypes: [])

        let container = try Container.resolve(components: components, configuration: configuration)
        defer { container.shutdown() }

        let identity = try #require(container.identity, "identity must be non-nil after a valid bootstrap")
        let runtime = try #require(container.runtime, "runtime must be non-nil after a valid bootstrap")
        let communicationManager = try #require(
            container.communicationManager,
            "communicationManager must be non-nil after a valid bootstrap"
        )

        #expect(identity.name == "test-agent")
        #expect(runtime.commonOptions?.agentIdentity?["name"] as? String == "test-agent")
        #expect(communicationManager.identity.name == "test-agent")
    }

    // MARK: - Controller lifecycle ordering

    /// Controllers registered before preparation are prepared once before the
    /// communication manager activates them.
    @Test
    func controllersRegisteredBeforePreparationArePreparedBeforeActivation() async throws {
        let container = try makeLifecycleContainer(
            controllers: ["initial": LifecycleOrderController.self]
        )
        defer { container.shutdown() }

        let initial = try #require(
            container.getController(name: "initial") as? LifecycleOrderController
        )
        try container.registerController(
            name: "before-preparation",
            controllerType: LifecycleOrderController.self
        )
        let beforePreparation = try #require(
            container.getController(name: "before-preparation") as? LifecycleOrderController
        )

        _ = await container.prepareControllersForCommunication()
        #expect(initial.events == ["init", "prepare"])
        #expect(beforePreparation.events == ["init", "prepare"])

        let communicationManager = try #require(container.communicationManager)
        try communicationManager.start()
        try await waitForActivation(of: initial)
        try await waitForActivation(of: beforePreparation)

        #expect(initial.events == ["init", "prepare", "starting"])
        #expect(beforePreparation.events == ["init", "prepare", "starting"])
    }

    /// A controller registered after the preparation pass still receives
    /// preparation before it is activated on the next manager start.
    @Test
    func controllersRegisteredAfterPreparationArePreparedBeforeActivation() async throws {
        let container = try makeLifecycleContainer(
            controllers: ["initial": LifecycleOrderController.self]
        )
        defer { container.shutdown() }

        let initial = try #require(
            container.getController(name: "initial") as? LifecycleOrderController
        )
        _ = await container.prepareControllersForCommunication()

        try container.registerController(
            name: "after-preparation",
            controllerType: LifecycleOrderController.self
        )
        let afterPreparation = try #require(
            container.getController(name: "after-preparation") as? LifecycleOrderController
        )

        let communicationManager = try #require(container.communicationManager)
        try communicationManager.start()
        try await waitForActivation(of: initial)
        try await waitForActivation(of: afterPreparation)

        #expect(initial.events == ["init", "prepare", "starting"])
        #expect(afterPreparation.events == ["init", "prepare", "starting"])
    }

    /// A controller registered while the manager is running is activated by
    /// the replayed operating state, without duplicate lifecycle hooks or
    /// preparation on a later stop/start cycle.
    @Test
    func controllersRegisteredWhileRunningHaveOnePreparationAndActivation() async throws {
        let container = try makeLifecycleContainer(controllers: [:])
        defer { container.shutdown() }

        let communicationManager = try #require(container.communicationManager)
        try communicationManager.start()

        try container.registerController(
            name: "while-running",
            controllerType: LifecycleOrderController.self
        )
        let controller = try #require(
            container.getController(name: "while-running") as? LifecycleOrderController
        )

        try await waitForActivation(of: controller)
        communicationManager.stop()
        try await waitForStopping(of: controller)
        try communicationManager.start()
        try await waitForActivation(of: controller, count: 2)

        #expect(controller.events == ["init", "prepare", "starting", "stopping", "starting"])
    }
}

@MainActor
private final class LifecycleOrderController: Controller, @unchecked Sendable {
    private(set) var events = [String]()

    override func onInit() {
        events.append("init")
        super.onInit()
    }

    override func prepareForCommunication() async {
        events.append("prepare")
        await Task.yield()
    }

    override func onCommunicationManagerStarting() {
        events.append("starting")
        super.onCommunicationManagerStarting()
    }

    override func onCommunicationManagerStopping() {
        events.append("stopping")
        super.onCommunicationManagerStopping()
    }
}

@MainActor
private func makeLifecycleContainer(
    controllers: [String: Controller.Type]
) throws -> Container {
    let communication = CommunicationOptions(
        mqttClientOptions: MQTTClientOptions(
            host: "127.0.0.1",
            port: 1,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        ),
        shouldAutoStart: false
    )
    return try Container.resolve(
        components: Components(controllers: controllers, objectTypes: []),
        configuration: Configuration(communication: communication)
    )
}

@MainActor
private func waitForActivation(
    of controller: LifecycleOrderController,
    count: Int = 1
) async throws {
    try await waitForEvent("starting", in: controller, count: count)
}

@MainActor
private func waitForStopping(of controller: LifecycleOrderController) async throws {
    try await waitForEvent("stopping", in: controller)
}

@MainActor
private func waitForEvent(
    _ event: String,
    in controller: LifecycleOrderController,
    count: Int = 1
) async throws {
    try await waitUntil("controller \(event)", timeout: .seconds(2)) {
        controller.events.filter { $0 == event }.count >= count
    }
}
