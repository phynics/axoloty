// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Testing

@Suite("MQTT client identity")
struct MQTTClientIdentityTests {
    @Test("client ID exposes the normalized agent role")
    @MainActor
    func descriptiveIdentity() throws {
        let options = try configuredOptions(name: "gnostic-chat-client", id: "01234567-89ab-4cde-8fab-0123456789ab")

        #expect(options.clientId == "gnosticCha0123456789abc")
        #expect(options.clientId?.utf8.count == 23)
        #expect(options.clientId?.allSatisfy(\.isASCIIAlphaNumeric) == true)
    }

    @Test("client IDs remain unique for agents sharing one role")
    @MainActor
    func uniqueIdentitySuffix() throws {
        let first = try configuredOptions(name: "gnostic-serve", id: "01234567-89ab-4cde-8fab-0123456789ab")
        let second = try configuredOptions(name: "gnostic-serve", id: "01234567-89ab-4dde-8fab-0123456789ab")

        #expect(first.clientId == "gnosticSer0123456789abc")
        #expect(second.clientId == "gnosticSer0123456789abd")
        #expect(first.clientId != second.clientId)
    }

    @Test("client ID falls back when the agent name has no compatible characters")
    @MainActor
    func unusableIdentityFallback() throws {
        let options = try configuredOptions(name: "🚀—", id: "01234567-89ab-4cde-8fab-0123456789ab")

        #expect(options.clientId == "Coaty0123456789ab4cde8f")
        #expect(options.clientId?.utf8.count == 23)
    }
}

@MainActor
private func configuredOptions(name: String, id: String) throws -> MQTTClientOptions {
    let options = MQTTClientOptions()
    let communication = CommunicationOptions(mqttClientOptions: options, shouldAutoStart: false)
    let objectID = try #require(CoatyUUID(uuidString: id))
    _ = try CommunicationManager(
        identity: Identity(name: name, objectId: objectID),
        communicationOptions: communication,
        commonOptions: nil
    )
    return options
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)
        } == true
    }
}
