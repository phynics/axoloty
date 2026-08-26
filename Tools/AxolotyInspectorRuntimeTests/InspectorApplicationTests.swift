// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

@MainActor
private final class SuspendedInspectorSession: InspectorSession {
    private(set) var connectStarted = false
    private(set) var stopCount = 0

    func connect() async throws {
        connectStarted = true
        try await Task.sleep(for: .seconds(60))
    }

    func transportState() async -> InspectorTransportState {
        .offline
    }

    func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func discover(_ event: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func stop() {
        stopCount += 1
    }
}

private final class TestInspectorSignalHandler: InspectorSignalHandling {
    var wasInterrupted = false

    func install() {}
}

private enum RunObservation: Sendable {
    case finished(InspectorError?)
    case timedOut
}

@Test
@MainActor
func interruptionDuringInitialConnectionReturnsPromptlyAndStopsSession() async {
    let session = SuspendedInspectorSession()
    let signalHandler = TestInspectorSignalHandler()
    let application = InspectorApplication(
        configuration: InspectorConfiguration(
            command: .catalog(CatalogCommand()),
            connection: InspectorConnectionConfiguration(
                host: "localhost",
                port: 1883,
                namespace: "test"
            ),
            output: .ndjson
        ),
        session: session,
        writeOutput: { _ in },
        writeDiagnostic: { _ in },
        timestamp: { "2026-01-01T00:00:00Z" },
        isTerminal: false,
        signalHandler: signalHandler
    )

    let runTask = Task { @MainActor in
        await application.run()
    }
    let connectionStarted = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !(await session.connectStarted) {
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
        group.addTask {
            // The tooling tier starts many suites concurrently on CI; allow
            // the main-actor connection task to be scheduled before declaring
            // the startup observation missing.
            try? await Task.sleep(for: .seconds(5))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    guard connectionStarted else {
        runTask.cancel()
        session.stop()
        _ = await runTask.value
        Issue.record("Timed out waiting for inspector connect phase to start")
        return
    }
    signalHandler.wasInterrupted = true

    let observation = await withTaskGroup(of: RunObservation.self) { group in
        group.addTask {
            .finished(await runTask.value)
        }
        group.addTask {
            // Loaded CI runners can delay the task that observes the signal even
            // though the application normally returns in about 100 ms.
            try? await Task.sleep(for: .seconds(5))
            return .timedOut
        }

        let first = await group.next()!
        group.cancelAll()
        if case .timedOut = first {
            runTask.cancel()
            session.stop()
        }
        return first
    }

    switch observation {
    case let .finished(result):
        #expect(result == InspectorError.interrupted)
        #expect(session.stopCount == 1)
    case .timedOut:
        Issue.record("Initial connection did not stop promptly after interruption")
    }
}
