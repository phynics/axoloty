// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("builder seals typed event streams and responders")
    func builderSealsModernContracts() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "inspector")
        var builder = try RuntimeBuilder(identity: identity, namespace: "building-a")
        _ = try builder.events(
            matching: .family(.advertise),
            buffering: .coalesceLatest
        )
        _ = try builder.respond(
            to: .call(operation: "device.read"),
            maximumConcurrentInvocations: 1
        ) { _ in .noResponse }
        let sealed = try builder.finish()
        #expect(sealed.identity == identity)
        #expect(sealed.handlerCount == 1)
    }

    @Test("Call responders reject MQTT-invalid operation names")
    func rejectsInvalidResponderOperationNames() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "invalid-operation-test")
        var builder = try RuntimeBuilder(identity: identity, namespace: "test")
        do {
            _ = try builder.respond(to: .call(operation: "invalid\0operation")) { _ in .noResponse }
            Issue.record("the responder accepted an operation name containing NUL")
        } catch let error as AxolotyError {
            guard case let .invalidArgument(argument, _) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(argument == "operation")
        }
    }

    @Test("non-Call handlers reject operation filters")
    func rejectsNonCallOperationFilters() throws {
        let identity = try RuntimeIdentity(id: .zero, name: "non-call-operation-test")
        var builder = try RuntimeBuilder(identity: identity, namespace: "test")
        do {
            _ = try builder.respond(to: .advertise, operation: "not-a-call") { _ in .noResponse }
            Issue.record("the non-Call handler accepted an operation filter")
        } catch let error as AxolotyError {
            guard case let .invalidArgument(argument, _) = error else {
                Issue.record("unexpected error: \(error.userFriendlyMessage)")
                return
            }
            #expect(argument == "operation")
        }
    }
}
