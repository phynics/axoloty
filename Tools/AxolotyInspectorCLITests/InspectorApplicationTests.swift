// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyInspectorCLI
import Axoloty
import AxolotyInspectorCore
import Foundation
import Testing

@MainActor
final class FakeInspectorSession: InspectorSession {
    var connectShouldFail = false
    var connectError: InspectorError?
    var connected = false
    var stopped = false
    var streamsCreatedBeforeConnect = false

    private var advertiseContinuation: AsyncStream<AdvertiseEventSnapshot>.Continuation?
    private var deadvertiseContinuation: AsyncStream<DeadvertiseEventSnapshot>.Continuation?

    private var advertiseStreamCreated = false
    private var deadvertiseStreamCreated = false

    var queuedAdvertises: [AdvertiseEventSnapshot] = []
    var queuedDeadvertises: [DeadvertiseEventSnapshot] = []

    func connect() async throws {
        if connectShouldFail {
            throw connectError ?? .connectionUnavailable(reason: "fake failure")
        }
        connected = true
        streamsCreatedBeforeConnect = advertiseStreamCreated && deadvertiseStreamCreated
        for snapshot in queuedAdvertises {
            advertiseContinuation?.yield(snapshot)
        }
        for snapshot in queuedDeadvertises {
            deadvertiseContinuation?.yield(snapshot)
        }
    }

    func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot> {
        let (stream, cont) = AsyncStream.makeStream(of: AdvertiseEventSnapshot.self)
        advertiseContinuation = cont
        advertiseStreamCreated = true
        return stream
    }

    func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot> {
        let (stream, cont) = AsyncStream.makeStream(of: DeadvertiseEventSnapshot.self)
        deadvertiseContinuation = cont
        deadvertiseStreamCreated = true
        return stream
    }

    func stop() {
        stopped = true
        advertiseContinuation?.finish()
        deadvertiseContinuation?.finish()
    }

    func emitAdvertise(_ snapshot: AdvertiseEventSnapshot) {
        advertiseContinuation?.yield(snapshot)
    }

    func emitDeadvertise(_ snapshot: DeadvertiseEventSnapshot) {
        deadvertiseContinuation?.yield(snapshot)
    }

    func endStreams() {
        advertiseContinuation?.finish()
        deadvertiseContinuation?.finish()
    }
}

@MainActor
@Suite
struct InspectorApplicationTests {

    private func makeConfig(
        duration: Duration = .milliseconds(200),
        output: InspectorOutputMode = .ndjson,
        full: Bool = false,
        includePrivateData: Bool = false,
        coreType: String? = nil,
        objectType: String? = nil
    ) -> InspectorConfiguration {
        InspectorConfiguration(
            command: .catalog(CatalogCommand(
                duration: InspectorDuration(value: duration),
                coreType: coreType,
                objectType: objectType,
                full: full,
                includePrivateData: includePrivateData
            )),
            connection: InspectorConnectionConfiguration(
                host: "localhost", port: 1883, namespace: "test"
            ),
            output: output
        )
    }

    private func makeSnapshot(
        objectId: String = "obj-1",
        coreType: CoreType = .Identity,
        objectType: String = "coaty.object.Identity",
        name: String = "Agent",
        sourceId: String? = "src-1"
    ) -> AdvertiseEventSnapshot {
        AdvertiseEventSnapshot(
            sourceId: sourceId,
            eventTypeFilter: coreType.rawValue,
            object: CoatyObjectSnapshot(
                objectId: objectId,
                coreType: coreType,
                objectType: objectType,
                name: name
            )
        )
    }

    @Test
    func streamsEstablishedBeforeConnect() async {
        let session = FakeInspectorSession()
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        #expect(session.streamsCreatedBeforeConnect)
        #expect(session.stopped)
    }

    @Test
    func advertiseProducesOutput() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(name: "Agent A")]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(output: .ndjson),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result == nil)
        #expect(session.stopped)
        let advertiseLines = output.filter { $0.contains("\"kind\":\"advertise\"") }
        #expect(advertiseLines.count == 1)
        #expect(advertiseLines[0].contains("\"name\":\"Agent A\""))
    }

    @Test
    func deadvertiseRemovesFromCatalogue() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(objectId: "obj-1", name: "Agent")]
        session.queuedDeadvertises = [DeadvertiseEventSnapshot(sourceId: "src-1", objectIds: ["obj-1"])]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        let deadvertiseLines = output.filter { $0.contains("\"kind\":\"deadvertise\"") }
        #expect(deadvertiseLines.count == 1)
        #expect(deadvertiseLines[0].contains("\"objectId\":\"obj-1\""))
    }

    @Test
    func duplicateAdvertiseSuppressed() async {
        let snapshot = makeSnapshot(name: "Agent")
        let session = FakeInspectorSession()
        session.queuedAdvertises = [snapshot, snapshot]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        let advertiseLines = output.filter { $0.contains("\"kind\":\"advertise\"") }
        #expect(advertiseLines.count == 1)
    }

    @Test
    func sessionStopsAfterSuccess() async {
        let session = FakeInspectorSession()
        let app = InspectorApplication(
            configuration: makeConfig(duration: .milliseconds(50)),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result == nil)
        #expect(session.stopped)
    }

    @Test
    func sessionStopsAfterConnectFailure() async {
        let session = FakeInspectorSession()
        session.connectShouldFail = true
        session.connectError = .connectionUnavailable(reason: "broker unreachable")

        var diagnostics: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { diagnostics.append($0) },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result != nil)
        #expect(session.stopped)
        #expect(diagnostics.contains { $0.contains("broker unreachable") })
    }

    @Test
    func sessionStopsAfterInterruption() async {
        let session = FakeInspectorSession()
        let signalHandler = FakeSignalHandler()
        signalHandler.wasInterrupted = true

        let app = InspectorApplication(
            configuration: makeConfig(duration: .seconds(60)),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false,
            signalHandler: signalHandler
        )
        let result = await app.run()

        #expect(result == .interrupted)
        #expect(session.stopped)
    }

    @Test
    func humanOutputForTerminal() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(name: "Agent A")]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(output: .auto),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: true
        )
        _ = await app.run()

        let dataLines = output.filter { !$0.contains("CONNECTED") && !$0.contains("DISCONNECTED") }
        #expect(dataLines.contains { $0.contains("ADD") })
        #expect(dataLines.contains { $0.contains("Agent A") })
    }

    @Test
    func ndjsonOutputForPipe() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot()]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(output: .auto),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        let dataLines = output.filter { !$0.contains("CONNECTED") && !$0.contains("DISCONNECTED") }
        #expect(dataLines.contains { $0.contains("\"schema\":\"axoloty.inspect/v1\"") })
    }

    @Test
    func stdoutAndStderrSeparated() async {
        let session = FakeInspectorSession()
        session.connectShouldFail = true

        var output: [String] = []
        var diagnostics: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { diagnostics.append($0) },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        #expect(output.isEmpty)
        #expect(!diagnostics.isEmpty)
    }

    @Test
    func streamEndedProducesError() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = []

        let app = InspectorApplication(
            configuration: makeConfig(duration: .seconds(60)),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let runTask = Task { await app.run() }

        try? await Task.sleep(for: .milliseconds(100))
        session.endStreams()

        let result = await runTask.value

        if let result {
            #expect(result == .connectionUnavailable(reason: "event stream ended unexpectedly"))
        } else {
            Issue.record("Expected error result")
        }
        #expect(session.stopped)
    }

    @Test
    func cancellationDoesNotEmitFalseFailure() async {
        let session = FakeInspectorSession()
        let signalHandler = FakeSignalHandler()
        signalHandler.wasInterrupted = true

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(duration: .seconds(60)),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false,
            signalHandler: signalHandler
        )
        let result = await app.run()

        #expect(result == .interrupted)
        let errorLines = output.filter { $0.contains("\"kind\":\"error\"") }
        #expect(errorLines.isEmpty)
    }
}
