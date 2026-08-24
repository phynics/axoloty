// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation
import Testing

/// Exercises the modern runtime's Associate and IoValue producer path against
/// the pinned CoatyJS IO actor.
@MainActor
struct AxolotyIoAssociateTests {
    private static let sourceID = UUID16(parsing: "33333333-3333-4333-8333-333333333333")!
    private static let actorID = "44444444-4444-4444-8444-444444444444"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_MODERN_TO_JS_LIVE"] == "1"))
    func publishesAssociateAndIoValueForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let contextName = environment["IO_CONTEXT_NAME"] ?? "wire-compat-io-context-1"
        let identity = try RuntimeIdentity(id: Self.sourceID, name: "axoloty-io-source")
        let builder = try RuntimeDefinition.Builder(identity: identity, namespace: namespace)
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
        let route = "coaty/3/\(namespace)/IOV/33333333-3333-4333-8333-333333333333"
        let associate = Array("{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"\(Self.actorID)\",\"associatingRoute\":\"\(route)\",\"updateRate\":250}".utf8)
        let disassociate = Array("{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"\(Self.actorID)\"}".utf8)
        do {
            try await runtime.start()
            ModernConsumerSupport.emit("{\"state\":\"ready\",\"scenario\":\"io-associate\",\"route\":\"\(route)\"}")
            let associateOperation = RuntimeOneWayOperation.associateInContext(
                contextName: contextName,
                payload: associate
            )
            #expect(await runtime.publish(associateOperation) == .accepted)
            try await Task.sleep(for: .milliseconds(1_500))
            #expect(await runtime.publish(RuntimeOneWayOperation.ioValue(Array("42".utf8))) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"published-iovalue\",\"scenario\":\"io-associate\",\"route\":\"\(route)\"}")
            try await Task.sleep(for: .milliseconds(1_500))
            let disassociateOperation = RuntimeOneWayOperation.associateInContext(
                contextName: contextName,
                payload: disassociate
            )
            #expect(await runtime.publish(disassociateOperation) == .accepted)
            try await Task.sleep(for: .milliseconds(500))
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}
