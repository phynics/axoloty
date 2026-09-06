// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

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
        coreType: InspectorCoreType = .Identity,
        objectType: String = "coaty.object.Identity",
        name: String = "Agent",
        sourceId: String? = "src-1",
        privateData: String? = nil
    ) -> InspectorAdvertiseEvent {
        InspectorAdvertiseEvent(
            sourceId: sourceId,
            eventTypeFilter: coreType.rawValue,
            object: InspectorObjectPayload(
                objectId: objectId,
                coreType: coreType,
                objectType: objectType,
                name: name
            ),
            privateData: privateData
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
    func jsonCatalogBuffersRecordsAndEmitsOneArrayAtCompletion() async throws {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(name: "Agent A")]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(output: .json),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result == nil)
        #expect(output.count == 1)
        let records = try #require(JSONSerialization.jsonObject(with: Data(output[0].utf8)) as? [[String: Any]])
        #expect(records.count == 3)
        #expect(records.contains { $0["kind"] as? String == "advertise" })
    }

    @Test
    func deadvertiseRemovesFromCatalogue() async throws {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(objectId: "obj-1", name: "Agent")]

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        let app = InspectorApplication(
            configuration: makeConfig(),
            session: session,
            writeOutput: { outputContinuation.yield($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let runTask = Task {
            let result = await app.run()
            outputContinuation.finish()
            return result
        }
        var outputIterator = outputStream.makeAsyncIterator()

        var advertise: String?
        while let line = await outputIterator.next() {
            if line.contains("\"kind\":\"advertise\"") {
                advertise = line
                break
            }
        }
        _ = try #require(advertise)

        session.emitDeadvertise(InspectorDeadvertiseEvent(sourceId: "src-1", objectIds: ["obj-1"]))

        var deadvertise: String?
        while let line = await outputIterator.next() {
            if line.contains("\"kind\":\"deadvertise\"") {
                deadvertise = line
                break
            }
        }
        let deadvertiseLine = try #require(deadvertise)
        #expect(deadvertiseLine.contains("\"objectId\":\"obj-1\""))
        #expect(await runTask.value == nil)
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
        let hasSchema = dataLines.contains { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["schema"] != nil
        }
        #expect(hasSchema)
    }

    @Test
    func privateDataRequiresFullOutputAtApplicationBoundary() async {
        let session = FakeInspectorSession()
        session.queuedAdvertises = [makeSnapshot(privateData: "{\"secret\":true}")]

        var output: [String] = []
        let app = InspectorApplication(
            configuration: makeConfig(includePrivateData: true),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        #expect(output.allSatisfy { !$0.contains("secret") })
    }

    @Test
    func privateDataIsPresentOnlyWithBothFlagsInEveryOutputMode() async {
        for outputMode in [InspectorOutputMode.human, .ndjson, .json] {
            for (full, includePrivateData, expected) in [
                (false, false, false),
                (false, true, false),
                (true, false, false),
                (true, true, true),
            ] {
                let session = FakeInspectorSession()
                session.queuedAdvertises = [makeSnapshot(privateData: "{\"secret\":true}")]

                var output: [String] = []
                let app = InspectorApplication(
                    configuration: makeConfig(
                        duration: .milliseconds(100),
                        output: outputMode,
                        full: full,
                        includePrivateData: includePrivateData
                    ),
                    session: session,
                    writeOutput: { output.append($0) },
                    writeDiagnostic: { _ in },
                    timestamp: { "2026-07-31T00:00:00Z" },
                    isTerminal: outputMode == .human
                )
                _ = await app.run()

                #expect(output.contains { $0.contains("secret") } == expected)
            }
        }
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
