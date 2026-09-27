// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

import Axoloty
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
@testable import AxolotyZenoh

@Suite(
    "Zenoh live router integration",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ENDPOINT"] != nil)
)
struct ZenohLiveIntegrationTests {
    private var endpoint: String {
        ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ENDPOINT"] ?? ""
    }

    @Test("two Axoloty bindings exchange a profile route through zenohd")
    func axolotyToAxoloty() async throws {
        let namespace = "live-\(UUID().uuidString.lowercased())"
        let route = "coaty/3/\(namespace)/IOV/11111111-1111-4111-8111-111111111111"
        let receiver = FrameRecorder()
        let first = try ZenohBinding(connectEndpoint: endpoint)
        let second = try ZenohBinding(connectEndpoint: endpoint)
        try await withStoppedBindings([first, second]) {
            try await first.start { _ in }
            try await second.start { frame in receiver.append(frame) }
            try await first.activateProfileInterest(namespace: namespace)
            try await second.activateProfileInterest(namespace: namespace)
            try await waitFor("both Zenoh clients to connect to zenohd") {
                bindingRouterCount(first) > 0 && bindingRouterCount(second) > 0
            }

            try await publishUntil("Axoloty-to-Axoloty delivery", receive: {
                receiver.contains(route: route, payload: [7, 0, 9])
            }) {
                try await first.perform(.publish(RuntimeOutboundMessage(route: route, payload: [7, 0, 9])))
            }
        }
    }

    @Test("an external IO route is delivered through the real router")
    func externalIORoute() async throws {
        let route = "external/live/\(UUID().uuidString.lowercased())"
        let receiver = FrameRecorder()
        let publisher = try ZenohBinding(connectEndpoint: endpoint)
        let subscriber = try ZenohBinding(connectEndpoint: endpoint)
        try await withStoppedBindings([publisher, subscriber]) {
            try await publisher.start { _ in }
            try await subscriber.start { frame in receiver.append(frame) }
            try await subscriber.perform(.externalRouteActivated(OwnedExternalRouteTransition(
                sourceID: .zero,
                actorID: .zero,
                route: Array(route.utf8)
            )))

            try await publishUntil("external route delivery", receive: {
                receiver.contains(route: route, payload: [1, 2, 3])
            }) {
                try await publisher.perform(.publish(RuntimeOutboundMessage(route: route, payload: [1, 2, 3])))
            }
        }
    }

    @Test("an independent C Zenoh client publishes to Axoloty")
    func cClientToAxoloty() async throws {
        let route = "external/c-peer/\(UUID().uuidString.lowercased())"
        let receiver = FrameRecorder()
        let binding = try ZenohBinding(connectEndpoint: endpoint)
        try await withStoppedBindings([binding]) {
            try await binding.start { frame in receiver.append(frame) }
            try await binding.perform(.externalRouteActivated(OwnedExternalRouteTransition(
                sourceID: .zero,
                actorID: .zero,
                route: Array(route.utf8)
            )))

            try await waitFor("Axoloty client connection") { bindingRouterCount(binding) > 0 }
            try await publishFromCPeerUntilReceived(route: route, receiver: receiver)
            #expect(receiver.contains(route: route, payload: Array("independent-c-peer".utf8)))
        }
    }

    private func publishFromCPeerUntilReceived(route: String, receiver: FrameRecorder) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let (peer, _) = try makeCPeer(mode: "publish", route: route)
            try peer.run()
            peer.waitUntilExit()
            if peer.terminationStatus != 0 {
                Issue.record("independent C publisher exited with status \(peer.terminationStatus)")
                return
            }
            if receiver.contains(route: route, payload: Array("independent-c-peer".utf8)) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ZenohLiveTestFailure.timeout("independent C route delivery")
    }

    @Test("an independent C Zenoh client receives an Axoloty publication")
    func axolotyToCClient() async throws {
        let route = "external/c-subscriber/\(UUID().uuidString.lowercased())"
        let (peer, outputPipe) = try makeCPeer(mode: "subscribe", route: route)
        try peer.run()
        let output = CPeerOutput(pipe: outputPipe)
        defer {
            if peer.isRunning { peer.terminate() }
            peer.waitUntilExit()
        }
        try await waitFor("independent C subscriber readiness") { output.text.contains("READY") }

        let binding = try ZenohBinding(connectEndpoint: endpoint)
        try await withStoppedBindings([binding]) {
            try await binding.start { _ in }
            try await waitFor("Axoloty client connection") { bindingRouterCount(binding) > 0 }
            let payload = Array("axoloty-to-c-peer".utf8)
            try await publishUntil("Axoloty-to-C route delivery", receive: {
                output.text.contains("RECEIVED axoloty-to-c-peer")
            }) {
                try await binding.perform(.publish(RuntimeOutboundMessage(route: route, payload: payload)))
            }
        }
        #expect(output.text.contains("RECEIVED axoloty-to-c-peer"))
        try await waitFor("C peer shutdown") { !peer.isRunning }
        #expect(peer.terminationStatus == 0)
    }

    @Test("graceful shutdown closes the router session")
    func gracefulShutdown() async throws {
        let binding = try ZenohBinding(connectEndpoint: endpoint)
        try await binding.start { _ in }
        try await waitFor("client connection before graceful stop") { bindingRouterCount(binding) > 0 }
        await binding.stop()
        #expect(bindingRouterCount(binding) == 0)
    }

    @Test("the runtime enters soft recovery and resumes after router restart")
    func routerRestartRecovery() async throws {
        let namespace = "restart-\(UUID().uuidString.lowercased())"
        let receiver = FrameRecorder()
        let binding = try ZenohBinding(connectEndpoint: endpoint)
        let subscriber = try ZenohBinding(connectEndpoint: endpoint)
        let builder = try RuntimeBuilder(sourceID: .zero, namespace: namespace)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: binding)
        try await withStoppedRuntime(runtime, otherBindings: [subscriber]) {
            print("ZENOH_LIVE_RESTART_STAGE starting-runtime")
            try await runtime.start()
            print("ZENOH_LIVE_RESTART_STAGE runtime-started state=\(await runtime.state())")
            try await subscriber.start { frame in receiver.append(frame) }
            try await subscriber.activateProfileInterest(namespace: namespace)
            print("ZENOH_LIVE_RESTART_STAGE subscriber-started")
            try await waitFor("router presence before interruption") {
                bindingObservedRouter(binding) && bindingRouterCount(subscriber) > 0
            }
            print("ZENOH_LIVE_RESTART_STAGE router-observed")

            let pid = try #require(Int32(ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ROUTER_PID"] ?? ""))
            guard kill(pid, SIGKILL) == 0 else {
                throw ZenohLiveTestFailure.routerKillFailed(String(cString: strerror(errno)))
            }
            print("ZENOH_LIVE_RESTART_STAGE router-killed")
            let sessionsDetectedLoss = await eventually {
                bindingRouterCount(binding) == 0 && bindingRouterCount(subscriber) == 0
            }
            print("ZENOH_LIVE_RESTART_STAGE sessions-detected-loss=\(sessionsDetectedLoss)")
            let runtimeEnteredRecovery = await eventually { await runtime.state() == .reconnecting }
            print("ZENOH_LIVE_RESTART_STAGE runtime-entered-recovery=\(runtimeEnteredRecovery)")

            let routerPath = try #require(ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ROUTER"])
            let router = Process()
            router.executableURL = URL(fileURLWithPath: routerPath)
            router.arguments = ["-l", endpoint]
            router.standardOutput = FileHandle.nullDevice
            router.standardError = FileHandle.nullDevice
            try router.run()
            print("ZENOH_LIVE_RESTART_STAGE router-restarted pid=\(router.processIdentifier)")
            defer {
                if router.isRunning { kill(router.processIdentifier, SIGKILL) }
                router.waitUntilExit()
            }
            let routerRestored = await eventually {
                bindingRouterCount(binding) > 0 && bindingRouterCount(subscriber) > 0
            }
            print("ZENOH_LIVE_RESTART_STAGE router-restored=\(routerRestored)")
            let runtimeRecovered = await eventually {
                await runtime.state() == .running && bindingRouterCount(binding) > 0
            }
            print("ZENOH_LIVE_RESTART_STAGE runtime-recovered=\(runtimeRecovered)")
            let payload = Array(#"{"privateData":{"sequence":7}}"#.utf8)
            let messageResumed: Bool
            if runtimeRecovered {
                messageResumed = await publishRuntimeUntilReceived(
                    runtime,
                    payload: payload,
                    receiver: receiver
                )
            } else {
                messageResumed = false
            }
            print("ZENOH_LIVE_RESTART_STAGE message-resumed=\(messageResumed)")
            await runtime.stop()
            print("ZENOH_LIVE_RESTART_STAGE runtime-stopped")
            await subscriber.stop()
            print("ZENOH_LIVE_RESTART_STAGE subscriber-stopped")
            if router.isRunning { kill(router.processIdentifier, SIGKILL) }
            router.waitUntilExit()
            print("ZENOH_LIVE_RESTART_STAGE router-stopped")
            #expect(sessionsDetectedLoss, "Zenoh sessions did not report router absence")
            #expect(runtimeEnteredRecovery, "runtime did not enter reconnecting before router restart")
            #expect(routerRestored, "sessions did not reconnect to the restarted router")
            #expect(runtimeRecovered, "runtime did not recover automatically after router return")
            #expect(messageResumed, "runtime publication was not received after router recovery")
            #expect(!router.isRunning)
        }
    }

    private func publishRuntimeUntilReceived(
        _ runtime: AxolotyRuntime,
        payload: [UInt8],
        receiver: FrameRecorder
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let receipt = await runtime.publish(.channel(identifier: "restart-proof", payload: payload))
            guard receipt == .accepted else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if receiver.contains(payload: payload) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func eventually(
        timeout: Duration = .seconds(12),
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func publishUntil(
        _ description: String,
        timeout: Duration = .seconds(20),
        receive: @escaping () async -> Bool,
        publish: @escaping () async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await publish()
            if await receive() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ZenohLiveTestFailure.timeout(description)
    }

    private func withStoppedBindings(
        _ bindings: [ZenohBinding],
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            for binding in bindings { await binding.stop() }
            throw error
        }
        for binding in bindings { await binding.stop() }
    }

    private func withStoppedRuntime(
        _ runtime: AxolotyRuntime,
        otherBindings: [ZenohBinding],
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            print("ZENOH_LIVE_RESTART_STAGE cleanup-after-error")
            await runtime.stop()
            print("ZENOH_LIVE_RESTART_STAGE runtime-stopped-after-error")
            for binding in otherBindings { await binding.stop() }
            throw error
        }
        await runtime.stop()
        for binding in otherBindings { await binding.stop() }
    }

    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(12),
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ZenohLiveTestFailure.timeout(description)
    }

    private func bindingRouterCount(_ binding: ZenohBinding) -> UInt32 {
        ZenohBinding.sessionRegistryLock.withLock {
            if case let .count(count) = binding.session.connectedRouterCount() { return count }
            return 0
        }
    }

    private func bindingObservedRouter(_ binding: ZenohBinding) -> Bool {
        ZenohBinding.sessionRegistryLock.withLock { binding.hasObservedRouter }
    }

    private func makeCPeer(mode: String, route: String) throws -> (Process, Pipe) {
        let executable = try #require(ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_C_PEER"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [mode, endpoint, route]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        return (process, outputPipe)
    }
}

private enum ZenohLiveTestFailure: Error, LocalizedError {
    case timeout(String)
    case routerKillFailed(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(description): "Timed out waiting for \(description)"
        case let .routerKillFailed(reason): "Could not kill zenohd for restart scenario: \(reason)"
        }
    }
}

private final class CPeerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    init(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            self.lock.withLock { self.storage += String(decoding: data, as: UTF8.self) }
        }
    }

    var text: String { lock.withLock { storage } }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RuntimeInboundFrame] = []

    func contains(route: String, payload: [UInt8]) -> Bool {
        lock.withLock {
            storage.contains { frame in
                switch frame {
                case let .profile(frameRoute, framePayload, _), let .externalIo(frameRoute, framePayload, _):
                    return frameRoute == route && framePayload == payload
                }
            }
        }
    }

    func contains(payload: [UInt8]) -> Bool {
        lock.withLock {
            storage.contains { frame in
                switch frame {
                case let .profile(_, framePayload, _), let .externalIo(_, framePayload, _):
                    return framePayload == payload
                }
            }
        }
    }

    func append(_ frame: RuntimeInboundFrame) { lock.withLock { storage.append(frame) }
    }
}
