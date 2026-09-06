// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorConfigurationTests {
    @Test
    func connectionConfigurationRedactsPasswordInDescription() {
        let config = InspectorConnectionConfiguration(
            host: "broker.local",
            port: 1883,
            namespace: "test",
            username: "operator",
            password: "super-secret"
        )
        let description = String(describing: config)
        #expect(!description.contains("super-secret"))
        #expect(description.contains("password=***"))
        #expect(description.contains("username=***"))
    }

    @Test
    func connectionConfigurationNoCredentialsInDescription() {
        let config = InspectorConnectionConfiguration(
            host: "broker.local",
            port: 1883,
            namespace: "test"
        )
        let description = String(describing: config)
        #expect(description.contains("no-credentials"))
        #expect(!description.contains("password=***"))
    }

    @Test
    func configurationRedactsPasswordInDescription() {
        let config = InspectorConfiguration(
            command: .catalog(CatalogCommand()),
            connection: InspectorConnectionConfiguration(
                host: "broker.local",
                port: 1883,
                namespace: "test",
                password: "hidden"
            )
        )
        let description = String(describing: config)
        #expect(!description.contains("hidden"))
    }

    @Test
    func outputModeRawValues() {
        #expect(InspectorOutputMode.auto.rawValue == "auto")
        #expect(InspectorOutputMode.human.rawValue == "human")
        #expect(InspectorOutputMode.ndjson.rawValue == "ndjson")
        #expect(InspectorOutputMode.json.rawValue == "json")
    }

    @Test
    func errorExitCodes() {
        #expect(InspectorError.invalidArguments(reason: "test").exitCode == 64)
        #expect(InspectorError.invalidConfiguration(field: "port", reason: "bad").exitCode == 64)
        #expect(InspectorError.connectionUnavailable(reason: "down").exitCode == 69)
        #expect(InspectorError.authenticationFailed.exitCode == 69)
        #expect(InspectorError.protocolFailure(reason: "bad").exitCode == 1)
        #expect(InspectorError.outputFailure(reason: "bad").exitCode == 1)
        #expect(InspectorError.internalFailure(reason: "bad").exitCode == 1)
        #expect(InspectorError.interrupted.exitCode == 130)
    }

    @Test
    func errorUserFriendlyMessages() {
        #expect(InspectorError.invalidArguments(reason: "missing").userFriendlyMessage == "invalid arguments: missing")
        #expect(InspectorError.invalidConfiguration(field: "port", reason: "bad").userFriendlyMessage == "port: bad")
        #expect(InspectorError.authenticationFailed.userFriendlyMessage == "authentication failed")
        #expect(InspectorError.interrupted.userFriendlyMessage == "interrupted")
    }
}
