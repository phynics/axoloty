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
}
