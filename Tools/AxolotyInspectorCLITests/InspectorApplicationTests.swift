// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyInspectorCLI
import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

@MainActor
final class FakeInspectorSession: InspectorSession {
    var connectShouldFail = false
    var connectError: InspectorError?
    var connected = false
    var communicationState: CommunicationState = .offline
    var stopped = false
    var discoverCallCount = 0
    var streamsCreatedBeforeConnect = false

    private var advertiseContinuation: AsyncStream<AdvertiseEventSnapshot>.Continuation?
    private var deadvertiseContinuation: AsyncStream<DeadvertiseEventSnapshot>.Continuation?
    private var discoverContinuation: AsyncStream<ResponseEventSnapshot>.Continuation?

    private var advertiseStreamCreated = false
    private var deadvertiseStreamCreated = false

    var queuedAdvertises: [AdvertiseEventSnapshot] = []
    var queuedDeadvertises: [DeadvertiseEventSnapshot] = []
    var queuedResponses: [ResponseEventSnapshot] = []
    var finishDiscoverStream = true

    func connect() async throws {
        if connectShouldFail {
            throw connectError ?? .connectionUnavailable(reason: "fake failure")
        }
        connected = true
        communicationState = .online
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

    func communicationState() async -> CommunicationState {
        communicationState
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
        discoverContinuation?.finish()
    }

    func discover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        discoverCallCount += 1
        let (stream, cont) = AsyncStream.makeStream(of: ResponseEventSnapshot.self)
        discoverContinuation = cont
        for response in queuedResponses {
            cont.yield(response)
        }
        if finishDiscoverStream {
            cont.finish()
        }
        return stream
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

        session.emitDeadvertise(DeadvertiseEventSnapshot(sourceId: "src-1", objectIds: ["obj-1"]))

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

// MARK: - Discover application tests

@MainActor
@Suite
struct InspectorDiscoverApplicationTests {

    private func makeDiscoverConfig(
        timeout: InspectorDuration = InspectorDuration(value: .milliseconds(200)),
        coreType: String? = "Identity",
        objectType: String? = nil,
        objectId: String? = nil
    ) -> InspectorConfiguration {
        InspectorConfiguration(
            command: .discover(DiscoverCommand(
                coreType: coreType,
                objectType: objectType,
                objectId: objectId,
                timeout: timeout
            )),
            connection: InspectorConnectionConfiguration(
                host: "localhost", port: 1883, namespace: "test"
            ),
            output: .ndjson
        )
    }

    private func makeResolveResponse(
        objectId: String = "obj-1",
        coreType: CoreType = .Identity,
        objectType: String = "coaty.object.Identity",
        name: String = "Agent"
    ) -> ResponseEventSnapshot {
        let objectJSON = "{\"objectId\":\"\(objectId)\",\"coreType\":\"\(coreType.rawValue)\",\"objectType\":\"\(objectType)\",\"name\":\"\(name)\"}"
        let payload = "{\"object\":\(objectJSON)}"
        return ResponseEventSnapshot(
            eventType: "resolve",
            sourceId: "src-1",
            correlationId: "corr-1",
            payload: payload
        )
    }

    @Test
    func discoverCollectsResolveResponses() async {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: "obj-1", name: "Agent A"),
            makeResolveResponse(objectId: "obj-2", name: "Agent B"),
        ]

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result == nil)
        #expect(session.stopped)

        let resultLines = output.filter { $0.contains("\"kind\":\"discovery-result\"") }
        #expect(resultLines.count == 1)
        #expect(resultLines[0].contains("\"objects\""))
    }

    @Test
    func discoverDeduplicatesByObjectId() async {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: "dup-id", name: "Agent"),
            makeResolveResponse(objectId: "dup-id", name: "Agent"),
        ]

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        _ = await app.run()

        let resultLines = output.filter { $0.contains("\"kind\":\"discovery-result\"") }
        let json = try! JSONSerialization.jsonObject(with: Data(resultLines[0].utf8)) as! [String: Any]
        let objects = json["objects"] as! [[String: Any]]
        #expect(objects.count == 1)
    }

    @Test
    func discoverZeroResultsIsSuccessful() async {
        let session = FakeInspectorSession()
        session.queuedResponses = []

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(timeout: InspectorDuration(value: .milliseconds(100))),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result == nil)
        let resultLines = output.filter { $0.contains("\"kind\":\"discovery-result\"") }
        #expect(resultLines.count == 1)
        #expect(resultLines[0].contains("\"timedOut\":true"))
    }

    @Test
    func discoverFiniteTimeoutEndsOpenResponseStream() async {
        let session = FakeInspectorSession()
        session.finishDiscoverStream = false

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(
                timeout: InspectorDuration(value: .milliseconds(20))
            ),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        #expect(await app.run() == nil)
        let resultLines = output.filter { $0.contains("\"kind\":\"discovery-result\"") }
        #expect(resultLines.count == 1)
        #expect(resultLines[0].contains("\"timedOut\":true"))
    }

    @Test
    func discoverZeroTimeoutEndsOpenResponseStreamImmediately() async {
        let session = FakeInspectorSession()
        session.finishDiscoverStream = false

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(timeout: InspectorDuration(value: .zero)),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        #expect(await app.run() == nil)
        let resultLines = output.filter { $0.contains("\"kind\":\"discovery-result\"") }
        #expect(resultLines.count == 1)
        #expect(resultLines[0].contains("\"timedOut\":true"))
    }

    @Test
    func discoverUnlimitedWaitsForInterruptionWithoutDeadline() async {
        let session = FakeInspectorSession()
        session.finishDiscoverStream = false
        let signalHandler = FakeSignalHandler()
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(timeout: .unlimited),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false,
            signalHandler: signalHandler
        )

        let runTask = Task { await app.run() }
        try? await Task.sleep(for: .seconds(10) + .milliseconds(250))
        #expect(!session.stopped)

        signalHandler.wasInterrupted = true
        #expect(await runTask.value == .interrupted)
        #expect(session.stopped)
    }

    @Test
    func discoverSessionStopsAfterConnectFailure() async {
        let session = FakeInspectorSession()
        session.connectShouldFail = true

        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )
        let result = await app.run()

        #expect(result != nil)
        #expect(session.stopped)
    }

    @Test
    func invalidObjectIdDoesNotInvokeDiscovery() async {
        let session = FakeInspectorSession()
        var diagnostics: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(objectId: "not-a-uuid"),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { diagnostics.append($0) },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let result = await app.run()

        #expect(result == .invalidArguments(reason: "objectId must be a valid UUID: not-a-uuid"))
        #expect(session.discoverCallCount == 0)
        #expect(diagnostics.contains { $0.contains("valid UUID") })
    }

    @Test
    func invalidCoreTypeDoesNotInvokeDiscovery() async {
        let session = FakeInspectorSession()
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(coreType: "UnknownCoreType"),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let result = await app.run()

        #expect(result == .invalidArguments(reason: "coreType must be a known core type: UnknownCoreType"))
        #expect(session.discoverCallCount == 0)
    }
}
