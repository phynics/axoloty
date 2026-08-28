// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("definition seals a finite handler set")
    func definitionSealsHandlers() throws {
        let capacities = try RuntimeCapacities(handlers: 1)
        var definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: capacities
        )
        _ = try definition.register(capability: .ioValue) { _ in .noResponse }
        let sealed = try definition.seal()
        #expect(sealed.capacities.handlers == 1)
        #expect(sealed.handlerCount == 1)
    }

    @Test("definition rejects MQTT-invalid namespace bytes")
    func rejectsInvalidNamespaceBytes() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "namespace-test")
        #expect(throws: AxolotyError.self) {
            _ = try RuntimeDefinition.Builder(identity: identity, namespace: "building\0a")
        }
    }

    @Test("definition namespace leaves room for the largest generated profile topic")
    func definitionBoundsNamespaceForGeneratedTopics() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "namespace-test")
        _ = try RuntimeDefinition.Builder(
            identity: identity,
            namespace: String(repeating: "n", count: 64)
        )
        #expect(throws: AxolotyError.self) {
            _ = try RuntimeDefinition.Builder(
                identity: identity,
                namespace: String(repeating: "n", count: 65)
            )
        }
    }

    @Test("definition bounds event-stream registration")
    func definitionBoundsEventStreams() throws {
        let capacities = try RuntimeCapacities(eventStreams: 1)
        var definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: capacities
        )
        _ = try definition.registerEvents(
            matching: .family(.advertise),
            buffering: .failAfterDrop(capacity: 1)
        )
        do {
            _ = try definition.registerEvents(
                matching: .family(.deadvertise),
                buffering: .coalesceLatest
            )
            Issue.record("event-stream registration exceeded its configured capacity")
        } catch let error as AxolotyError {
            guard case let .runtime(code, reason) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(code == .capacityExceeded)
            #expect(reason == "runtime event-stream capacity is full")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
