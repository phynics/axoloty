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

@Suite("Zenoh live router integration", .serialized)
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
        Issue.record("Timed out waiting for independent C route delivery")
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

    @Test("the runtime enters soft recovery and resumes after router restart")
    func routerRestartRecovery() async throws {
        let namespace = "restart-\(UUID().uuidString.lowercased())"
        let receiver = FrameRecorder()
        let binding = try ZenohBinding(connectEndpoint: endpoint)
        let subscriber = try ZenohBinding(connectEndpoint: endpoint)
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: namespace)
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: binding)
        try await withStoppedRuntime(runtime, otherBindings: [subscriber]) {
            try await runtime.start()
            try await subscriber.start { frame in receiver.append(frame) }
            try await subscriber.activateProfileInterest(namespace: namespace)
            try await waitFor("router presence before interruption") {
                bindingRouterCount(binding) > 0 && bindingRouterCount(subscriber) > 0
            }

            let pid = try #require(Int32(ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ROUTER_PID"] ?? ""))
            kill(pid, SIGKILL)
            try await waitFor("runtime to enter soft recovery after debounced router loss") {
                await runtime.state() == .reconnecting
            }

            let routerPath = try #require(ProcessInfo.processInfo.environment["AXOLOTY_ZENOH_LIVE_ROUTER"])
            let router = Process()
            router.executableURL = URL(fileURLWithPath: routerPath)
            router.arguments = ["-l", endpoint]
            router.standardOutput = FileHandle.nullDevice
            router.standardError = FileHandle.nullDevice
            try router.run()
            defer {
                if router.isRunning { router.terminate() }
                router.waitUntilExit()
            }
            try await waitFor("runtime automatic soft recovery") {
                await runtime.state() == .running && bindingRouterCount(binding) > 0
            }
            let payload = Array("resumed-after-router-restart".utf8)
            try await publishUntil("runtime publication after automatic recovery", receive: {
                receiver.contains(routePrefix: "coaty/3/\(namespace)/CHN/", payload: payload)
            }) {
                let identifier = UUID().uuidString.lowercased()
                #expect(await runtime.publish(.channel(identifier: identifier, payload: payload)) == .accepted)
            }
            await runtime.stop()
            await subscriber.stop()
            if router.isRunning { router.terminate() }
            router.waitUntilExit()
            #expect(!router.isRunning)
        }
    }

    @Test("graceful shutdown closes the router session")
    func gracefulShutdown() async throws {
        let binding = try ZenohBinding(connectEndpoint: endpoint)
        try await binding.start { _ in }
        try await waitFor("client connection before graceful stop") { bindingRouterCount(binding) > 0 }
        await binding.stop()
        #expect(bindingRouterCount(binding) == 0)
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
        Issue.record("Timed out waiting for \(description)")
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
            await runtime.stop()
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
        Issue.record("Timed out waiting for \(description)")
    }

    private func bindingRouterCount(_ binding: ZenohBinding) -> UInt32 {
        ZenohBinding.sessionRegistryLock.withLock {
            if case let .count(count) = binding.session.connectedRouterCount() { return count }
            return 0
        }
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

    func contains(routePrefix: String, payload: [UInt8]) -> Bool {
        lock.withLock {
            storage.contains { frame in
                switch frame {
                case let .profile(route, framePayload, _), let .externalIo(route, framePayload, _):
                    return route.hasPrefix(routePrefix) && framePayload == payload
                }
            }
        }
    }

    func append(_ frame: RuntimeInboundFrame) { lock.withLock { storage.append(frame) }
    }
}
