// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@_spi(AxolotyRuntimeAdapter) @testable import Axoloty
import AxolotyObjectModel
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("builder preserves registry identity, endpoint slots, and generations")
    func builderEndpointProvenance() throws {
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "provenance")
        let source = try builder.ioSource(metadata: runtimeSourceMetadata("{\"objectId\":\"00000000-0000-4000-8000-000000000201\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"), as: Bool.self)
        let actor = try builder.ioActor(metadata: runtimeActorMetadata("{\"objectId\":\"00000000-0000-4000-8000-000000000202\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"), as: Bool.self) { _, _ in }
        #expect(source.runtimeSlot == 0)
        #expect(actor.runtimeSlot == 1)
        #expect(builder.registrations.endpointGenerations == [1, 1])
        #expect(source.matches(
            registryID: builder.registrations.registryID,
            slot: source.runtimeSlot,
            generation: builder.registrations.endpointGenerations[0],
            id: source.id,
            representation: .json
        ))
        #expect(!source.matches(
            registryID: builder.registrations.registryID,
            slot: source.runtimeSlot,
            generation: 2,
            id: source.id,
            representation: .binary
        ))
        let definition = try builder.finish()
        #expect(definition.ioEndpointCount == 2)
    }

    @Test("builder finishes an immutable definition with registered handlers")
    func builderFinishesHandlers() throws {
        let capacities = try RuntimeCapacities(handlers: 1)
        var builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: capacities
        )
        _ = try builder.respond(to: .ioValue) { _ in .noResponse }
        #expect(builder.capacities == capacities)
        let definition = try builder.finish()
        #expect(definition.capacities.handlers == 1)
        #expect(definition.handlerCount == 1)
    }

    @Test("definition rejects MQTT-invalid namespace bytes")
    func rejectsInvalidNamespaceBytes() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "namespace-test")
        #expect(throws: AxolotyError.self) {
            _ = try RuntimeBuilder(identity: identity, namespace: "building\0a")
        }
    }

    @Test("definition namespace leaves room for the largest generated profile topic")
    func definitionBoundsNamespaceForGeneratedTopics() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "namespace-test")
        _ = try RuntimeBuilder(
            identity: identity,
            namespace: String(repeating: "n", count: 64)
        )
        #expect(throws: AxolotyError.self) {
            _ = try RuntimeBuilder(
                identity: identity,
                namespace: String(repeating: "n", count: 65)
            )
        }
    }

    @Test("definition bounds event-stream registration")
    func definitionBoundsEventStreams() throws {
        let capacities = try RuntimeCapacities(eventStreams: 1)
        var builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "test",
            capacities: capacities
        )
        _ = try builder.events(
            matching: .family(.advertise),
            buffering: .failAfterDrop(capacity: 1)
        )
        do {
            _ = try builder.events(
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

    @Test("failed module registration commits no handlers streams or correlation")
    func failedModuleRegistrationIsAtomic() throws {
        struct RegistrationFailure: Error {}
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "atomic")
        var provisionalCorrelation: UUID16?

        do {
            try builder.withRuntimeModule(key: "failing") { draft -> (RuntimeModuleRegistration, Void) in
                _ = try draft.respond(to: .ioValue) { _ in .noResponse }
                _ = try draft.events(matching: .family(.advertise), buffering: .coalesceLatest)
                _ = try draft.ioSource(metadata: runtimeSourceMetadata("{\"objectId\":\"00000000-0000-4000-8000-000000000203\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"), as: Bool.self)
                _ = try draft.ioActor(metadata: runtimeActorMetadata("{\"objectId\":\"00000000-0000-4000-8000-000000000204\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"), as: Bool.self) { _, _ in }
                provisionalCorrelation = try draft.reserveRuntimeModuleCorrelationID()
                throw RegistrationFailure()
            }
            Issue.record("failed module registration unexpectedly succeeded")
        } catch is RegistrationFailure {
            // Expected. The draft must be discarded in its entirety.
        }

        #expect(provisionalCorrelation != nil)
        let committedCorrelation = try builder.reserveRuntimeModuleCorrelationID()
        #expect(committedCorrelation == provisionalCorrelation)
        let definition = try builder.finish()
        #expect(definition.handlerCount == 0)
        #expect(definition.eventStreamCount == 0)
        #expect(definition.moduleCount == 0)
    }

    @Test("nested duplicate module keys roll back the complete outer draft")
    func nestedDuplicateModuleKeyIsAtomic() throws {
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "nested-duplicate")
        var provisionalCorrelation: UUID16?

        do {
            try builder.withRuntimeModule(key: "outer") { draft -> (RuntimeModuleRegistration, Void) in
                _ = try draft.respond(to: .ioValue) { _ in .noResponse }
                _ = try draft.events(matching: .family(.advertise), buffering: .coalesceLatest)
                _ = try draft.ioSource(metadata: runtimeSourceMetadata("{\"objectId\":\"00000000-0000-4000-8000-000000000205\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"), as: Bool.self)
                provisionalCorrelation = try draft.reserveRuntimeModuleCorrelationID()
                try draft.withRuntimeModule(key: "outer") { _ -> (RuntimeModuleRegistration, Void) in
                    (RuntimeModuleRegistration(run: { _ in }), ())
                }
                return (RuntimeModuleRegistration(run: { _ in }), ())
            }
            Issue.record("nested duplicate module key unexpectedly succeeded")
        } catch let error as AxolotyError {
            guard case let .runtime(code, reason) = error else {
                Issue.record("unexpected nested duplicate-module error: \(error.userFriendlyMessage)")
                return
            }
            #expect(code == .capacityExceeded)
            #expect(reason == "runtime module key is already registered")
        } catch {
            Issue.record("unexpected nested duplicate-module error: \(error)")
        }

        #expect(provisionalCorrelation != nil)
        #expect(builder.registrations.handlers.isEmpty)
        #expect(builder.registrations.eventRegistrations.isEmpty)
        #expect(builder.registrations.ioEndpointRegistrations.isEmpty)
        #expect(builder.registrations.modules.isEmpty)
        #expect(builder.registrations.moduleKeys.isEmpty)
        let committedCorrelation = try builder.reserveRuntimeModuleCorrelationID()
        #expect(committedCorrelation == provisionalCorrelation)

        try builder.withRuntimeModule(
            key: "outer",
            registration: RuntimeModuleRegistration(run: { _ in })
        )
        #expect(try builder.finish().moduleCount == 1)
    }

    @Test("duplicate module keys are rejected without changing registration state")
    func duplicateModuleKeyIsAtomic() throws {
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "duplicate")
        let registration = RuntimeModuleRegistration(run: { _ in })
        _ = try builder.withRuntimeModule(key: "stable") { _ in (registration, ()) }

        do {
            _ = try builder.withRuntimeModule(key: "stable") { _ in (registration, ()) }
            Issue.record("duplicate module key unexpectedly succeeded")
        } catch let error as AxolotyError {
            guard case let .runtime(code, reason) = error else {
                Issue.record("unexpected duplicate-module error: \(error.userFriendlyMessage)")
                return
            }
            #expect(code == .capacityExceeded)
            #expect(reason == "runtime module key is already registered")
        } catch {
            Issue.record("unexpected duplicate-module error: \(error)")
        }

        let definition = try builder.finish()
        #expect(definition.moduleCount == 1)
        // A failed duplicate leaves the builder usable for later registration.
        var continued = try RuntimeBuilder(sourceID: .zero, namespace: "continued")
        try continued.withRuntimeModule(key: "first") { _ in (registration, ()) }
        try continued.withRuntimeModule(key: "second") { _ in (registration, ()) }
        #expect(try continued.finish().moduleCount == 2)
    }
}

private func runtimeSourceMetadata(_ id: StaticString) throws -> Object<IoSourceMetadata> {
    try Object<IoSourceMetadata>(decoding: ByteSlice(bytes: id.utf8Start, length: id.utf8CodeUnitCount))
}

private func runtimeActorMetadata(_ id: StaticString) throws -> Object<IoActorMetadata> {
    try Object<IoActorMetadata>(decoding: ByteSlice(bytes: id.utf8Start, length: id.utf8CodeUnitCount))
}
