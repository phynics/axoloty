// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
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

    static func next(
        from stream: RuntimeEventStream,
        timeout: Duration,
        scenario: String
    ) async throws -> RuntimeEventValue {
        let box = RuntimeEventIteratorBox(stream.makeAsyncIterator())
        return try await withThrowingTaskGroup(of: RuntimeEventValue?.self) { group in
            group.addTask { await box.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else {
                throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for CoatyJS \\(scenario)")
            }
            return value
        }
    }

    static func jsonObject(_ payload: [UInt8]) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw AxolotyError.decodingFailure(type: "JSON object", reason: "Expected an object payload")
        }
        return object
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

private final class RuntimeEventIteratorBox: @unchecked Sendable {
    var iterator: AsyncStream<RuntimeEventValue>.Iterator

    init(_ iterator: AsyncStream<RuntimeEventValue>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> RuntimeEventValue? {
        await iterator.next()
    }
}
