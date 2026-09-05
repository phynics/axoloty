// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyTestSupport
import AxolotyWire
import Foundation

enum ModernConsumerSupport {
    static let sourceID = UUID16(parsing: "33333333-3333-4333-8333-333333333333")!
    static let requesterID = UUID16(parsing: "22222222-2222-4222-8222-222222222222")!
    static let fixtureID = "11111111-1111-4111-8111-111111111111"
    static let fixtureType = "com.coaty.test.WireFixture"

    static func environment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    static func binding(environment: [String: String]) throws -> MQTTBinding {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        return try MQTTBinding(configuration: try MQTTBindingConfiguration(host: host, port: port))
    }

    static func namespace(environment: [String: String]) -> String {
        environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
    }

    static func identity(name: String) throws -> RuntimeIdentity {
        try RuntimeIdentity(id: sourceID, name: name)
    }

    static func signalReadiness(environment: [String: String]) throws {
        guard let path = environment["WIRE_READY_FILE"] else { return }
        try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Waits for the peer process to confirm that it decoded the subject's
    /// publication. Live producer subjects are orchestration participants,
    /// not standalone wire assertions: local queue acceptance is insufficient
    /// evidence when the broker or peer can silently drop traffic.
    ///
    /// The live runner supplies a run-scoped marker path and token. The peer
    /// writes an atomic JSON marker only after its field-level assertion has
    /// passed. Missing, stale, malformed, or mismatched markers remain a
    /// bounded failure with enough context to identify the scenario and route
    /// being exercised.
    static func awaitPeerAcknowledgement(
        environment: [String: String],
        scenario: String,
        context: String,
        timeout: Duration = .seconds(30)
    ) async throws {
        guard let path = environment["WIRE_PEER_ACK_FILE"], !path.isEmpty else {
            throw PeerAcknowledgementFailure(
                reason: "missing WIRE_PEER_ACK_FILE",
                scenario: scenario,
                context: context
            )
        }
        guard let token = environment["WIRE_PEER_ACK_TOKEN"], !token.isEmpty else {
            throw PeerAcknowledgementFailure(
                reason: "missing WIRE_PEER_ACK_TOKEN",
                scenario: scenario,
                context: context
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastDiagnostic = "marker missing"
        while clock.now < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                do {
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let phase = object?["phase"] as? String
                    let markerScenario = object?["scenario"] as? String
                    let markerToken = object?["token"] as? String
                    if phase == "peer-ack", markerScenario == scenario, markerToken == token {
                        return
                    }
                    lastDiagnostic = "marker mismatch phase=\(phase ?? "nil") scenario=\(markerScenario ?? "nil")"
                } catch {
                    lastDiagnostic = "marker is not valid JSON"
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw PeerAcknowledgementFailure(
            reason: "timed out waiting for peer acknowledgement (\(lastDiagnostic), file=\(path))",
            scenario: scenario,
            context: context
        )
    }

    static func next(
        from stream: RuntimeEventStream,
        timeout: Duration,
        scenario: String
    ) async throws -> RuntimeEventValue {
        var iterator = stream.makeAsyncIterator()
        do {
            return try await nextValue(&iterator, timeout: timeout)
        } catch {
            throw AxolotyError.runtime(
                code: .timedOut,
                reason: "Timed out waiting for CoatyJS \(scenario): \(error)"
            )
        }
    }

    static func jsonObject(_ payload: [UInt8]) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw AxolotyError.decodingFailure(type: "JSON object", reason: "Expected an object payload")
        }
        return object
    }

    static func jsonValue(_ payload: [UInt8]) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(payload), options: [.fragmentsAllowed])
    }

    static func fixturePayload(name: String = "wire-fixture", privateData: [String: Any]? = nil) throws -> [UInt8] {
        let object: [String: Any] = [
            "coreType": "CoatyObject",
            "objectType": fixtureType,
            "objectId": fixtureID,
            "name": name,
        ]
        var root: [String: Any] = ["object": object]
        if let privateData { root["privateData"] = privateData }
        return Array(try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
    }
}

private struct PeerAcknowledgementFailure: Error, CustomStringConvertible {
    let reason: String
    let scenario: String
    let context: String

    var description: String {
        "Peer acknowledgement failure: \(reason); phase=peer-ack scenario=\(scenario) context=\(context)"
    }
}
