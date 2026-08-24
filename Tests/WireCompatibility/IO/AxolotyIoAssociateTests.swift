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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_JS_TO_MODERN_LIVE"] == "1"))
    func receivesAssociateAndIoValueFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let identity = try RuntimeIdentity(
            id: UUID16(parsing: Self.actorID)!,
            name: "axoloty-io-actor"
        )
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: namespace)
        let associateStream = try builder.events(
            matching: .family(.associate),
            buffering: RuntimeBufferingPolicy.failAfterDrop(capacity: 4)
        )
        let valueStream = try builder.events(
            matching: .family(.ioValue),
            buffering: RuntimeBufferingPolicy.failAfterDrop(capacity: 4)
        )
        let runtime = AxolotyRuntime(
            definition: try builder.finish(),
            transport: try ModernConsumerSupport.binding(environment: environment)
        )
        do {
            try await runtime.start()
            ModernConsumerSupport.emit("{\"state\":\"ready\",\"scenario\":\"io-associate-js-to-modern\"}")
            let associate = try await ModernConsumerSupport.next(
                from: associateStream,
                timeout: .seconds(30),
                scenario: "io-associate Associate"
            )
            let associateObject = try ModernConsumerSupport.jsonObject(associate.value)
            #expect(associateObject["ioSourceId"] as? String == "33333333-3333-4333-8333-333333333333")
            #expect(associateObject["ioActorId"] as? String == Self.actorID)
            #expect((associateObject["associatingRoute"] as? String)?.contains("/IOV/") == true)
            #expect(associateObject["isExternalRoute"] == nil)

            let value = try await ModernConsumerSupport.next(
                from: valueStream,
                timeout: .seconds(30),
                scenario: "io-associate IoValue"
            )
            let valueObject = try ModernConsumerSupport.jsonObject(value.value)
            #expect(valueObject["payload"] as? Int == 42)
            ModernConsumerSupport.emit("{\"state\":\"ack\",\"scenario\":\"io-associate-js-to-modern\"}")
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

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
            #expect(await runtime.publish(RuntimeOneWayOperation.ioValue(Array("42".utf8))) == .accepted)
            ModernConsumerSupport.emit("{\"state\":\"published-iovalue\",\"scenario\":\"io-associate\",\"route\":\"\(route)\"}")
            ModernConsumerSupport.emit(
                "{\"state\":\"awaiting-peer-ack\",\"phase\":\"peer-ack\",\"scenario\":\"io-associate\",\"route\":\"\(route)\",\"sourceId\":\"\(Self.sourceID)\",\"actorId\":\"\(Self.actorID)\"}"
            )
            try await ModernConsumerSupport.awaitPeerAcknowledgement(
                environment: environment,
                scenario: "io-associate",
                context: "route=\(route) sourceId=\(Self.sourceID) actorId=\(Self.actorID)",
                timeout: .seconds(60)
            )
            let disassociateOperation = RuntimeOneWayOperation.associateInContext(
                contextName: contextName,
                payload: disassociate
            )
            #expect(await runtime.publish(disassociateOperation) == .accepted)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}
