// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyInspectorCLI
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

@Suite
struct InspectorLoggingTests {
    @Test
    func appliesEachSupportedLevelToDefaultLoggerLevel() {
        let originalLevel = LogManager.defaultLevel
        defer { LogManager.defaultLevel = originalLevel }

        for level in InspectorLogLevel.allCases {
            applyInspectorLogLevel(level)

            switch level {
            case .trace:
                #expect(LogManager.defaultLevel == .trace)
            case .debug:
                #expect(LogManager.defaultLevel == .debug)
            case .info:
                #expect(LogManager.defaultLevel == .info)
            case .notice:
                #expect(LogManager.defaultLevel == .notice)
            case .warning:
                #expect(LogManager.defaultLevel == .warning)
            case .error:
                #expect(LogManager.defaultLevel == .error)
            }
        }
    }

    @Test
    @MainActor
    func runInspectorAppliesLevelAfterSessionConstruction() async {
        let originalLevel = LogManager.defaultLevel
        defer { LogManager.defaultLevel = originalLevel }

        let session = LifecycleCheckingInspectorSession()
        let configuration = InspectorConfiguration(
            command: .discover(DiscoverCommand(coreType: "Identity")),
            connection: InspectorConnectionConfiguration(
                host: "broker.local",
                port: 1883,
                namespace: "test"
            ),
            output: .ndjson,
            logLevel: "debug"
        )

        let exitCode = await runInspector(
            configuration,
            sessionFactory: { _ in
                // Model the reset performed by Container.resolve during session construction.
                LogManager.defaultLevel = .error
                return session
            },
            signalHandler: FakeSignalHandler()
        )

        #expect(exitCode == 0)
        #expect(session.sawDebugLevelAtConnect)
        #expect(LogManager.defaultLevel == .debug)
    }
}

@MainActor
private final class LifecycleCheckingInspectorSession: InspectorSession {
    var sawDebugLevelAtConnect = false

    func connect() async throws {
        sawDebugLevelAtConnect = LogManager.defaultLevel == .debug
    }

    func communicationState() async -> CommunicationState {
        .online
    }

    func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func discover(_: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func stop() {}
}
