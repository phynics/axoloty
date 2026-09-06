// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing
private func waitForPhase(
    _ phase: OneShotPhase,
    description: String,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in phase.stream {
                return true
            }
            return false
        }
        group.addTask {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return false
            }
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        if !result {
            Issue.record("Timed out waiting for inspector phase: \(description)")
        }
        return result
    }
}

private enum BoundedRunObservation: Sendable {
    case finished(InspectorError?)
    case timedOut
}

private final class CompletionSignal: @unchecked Sendable {
    let stream: AsyncStream<InspectorError?>
    private let continuation: AsyncStream<InspectorError?>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: InspectorError?.self)
    }

    func signal(_ result: InspectorError?) {
        continuation.yield(result)
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

private func awaitBounded(
    _ completion: CompletionSignal,
    phase: String,
    timeout: Duration = .seconds(2),
    onTimeout: @escaping @MainActor @Sendable () -> Void
) async -> BoundedRunObservation {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    return await withTaskGroup(of: BoundedRunObservation.self) { group in
        group.addTask {
            for await result in completion.stream {
                return .finished(result)
            }
            return .timedOut
        }
        group.addTask {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return .timedOut
            }
            await onTimeout()
            Issue.record("Timed out waiting for inspector phase: \(phase)")
            return .timedOut
        }
        let result = await group.next() ?? .timedOut
        group.cancelAll()
        return result
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
        objectId: String? = nil,
        output: InspectorOutputMode = .ndjson
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
            output: output
        )
    }

    private func makeResolveResponse(
        objectId: String? = "obj-1",
        coreType: InspectorCoreType = .Identity,
        objectType: String = "coaty.object.Identity",
        name: String = "Agent",
        relatedObjectIds: [String] = []
    ) -> InspectorResponseEvent {
        var fields: [String] = []
        if let objectId {
            fields.append("\"object\":{\"objectId\":\"\(objectId)\",\"coreType\":\"\(coreType.rawValue)\",\"objectType\":\"\(objectType)\",\"name\":\"\(name)\"}")
        }
        let relatedJSON = relatedObjectIds.map { relatedId in
            "{\"objectId\":\"\(relatedId)\",\"coreType\":\"\(coreType.rawValue)\",\"objectType\":\"\(objectType)\",\"name\":\"Related\"}"
        }.joined(separator: ",")
        if !relatedObjectIds.isEmpty {
            fields.append("\"relatedObjects\":[\(relatedJSON)]")
        }
        let payload = "{\(fields.joined(separator: ","))}"
        return InspectorResponseEvent(
            eventType: "resolve",
            sourceId: "src-1",
            correlationId: "corr-1",
            payload: payload
        )
    }

    @Test
    func discoverCollectsResolveResponses() async throws {
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
        let json = try #require(JSONSerialization.jsonObject(with: Data(resultLines[0].utf8)) as? [String: Any])
        let objects = try #require(json["objects"] as? [[String: Any]])
        #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["obj-1", "obj-2"])
    }

    @Test
    func discoverPreservesRelatedObjects() async throws {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: "obj-1", relatedObjectIds: ["related-1"])
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

        let resultLine = try #require(output.first { $0.contains("\"kind\":\"discovery-result\"") })
        let json = try #require(JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [String: Any])
        let objects = try #require(json["objects"] as? [[String: Any]])
        let objectIds = Set(objects.compactMap { $0["objectId"] as? String })
        #expect(objectIds == ["obj-1", "related-1"])
        #expect(objects.count == 2)
    }

    @Test
    func discoverPreservesRelatedOnlyResponses() async throws {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: nil, relatedObjectIds: ["related-1", "related-2"])
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

        let resultLine = try #require(output.first { $0.contains("\"kind\":\"discovery-result\"") })
        let json = try #require(JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [String: Any])
        let objects = try #require(json["objects"] as? [[String: Any]])
        let objectIds = Set(objects.compactMap { $0["objectId"] as? String })
        #expect(objectIds == ["related-1", "related-2"])
        #expect(objects.count == 2)
    }

    @Test
    func discoverDeduplicatesPrimaryAndRelatedObjectsById() async throws {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: "obj-1", relatedObjectIds: ["obj-1", "related-1"]),
            makeResolveResponse(objectId: "related-1", relatedObjectIds: ["related-2", "obj-1"]),
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

        let resultLine = try #require(output.first { $0.contains("\"kind\":\"discovery-result\"") })
        let json = try #require(JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [String: Any])
        let objects = try #require(json["objects"] as? [[String: Any]])
        #expect(objects.count == 3)
        #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["obj-1", "related-1", "related-2"])
    }

    @Test
    func humanDiscoveryCountIncludesPrimaryAndRelatedObjects() async {
        let session = FakeInspectorSession()
        session.queuedResponses = [
            makeResolveResponse(objectId: "obj-1", relatedObjectIds: ["related-1", "related-2"])
        ]

        var output: [String] = []
        let app = InspectorDiscoverApplication(
            configuration: InspectorConfiguration(
                command: .discover(DiscoverCommand(
                    coreType: "Identity",
                    timeout: InspectorDuration(value: .milliseconds(200))
                )),
                connection: InspectorConnectionConfiguration(
                    host: "localhost", port: 1883, namespace: "test"
                ),
                output: .human
            ),
            session: session,
            writeOutput: { output.append($0) },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: true
        )
        _ = await app.run()

        #expect(output.contains("DISCOVERY  3 objects (timed out)"))
    }

    @Test
    func structuredDiscoveryOutputsIncludePrimaryAndRelatedObjects() async throws {
        for outputMode in [InspectorOutputMode.ndjson, .json] {
            let session = FakeInspectorSession()
            session.queuedResponses = [
                makeResolveResponse(objectId: "primary-1", relatedObjectIds: ["related-1", "related-2"])
            ]

            var output: [String] = []
            let app = InspectorDiscoverApplication(
                configuration: makeDiscoverConfig(output: outputMode),
                session: session,
                writeOutput: { output.append($0) },
                writeDiagnostic: { _ in },
                timestamp: { "2026-07-31T00:00:00Z" },
                isTerminal: false
            )
            _ = await app.run()

            let resultLine = try #require(output.first { $0.contains("\"kind\":\"discovery-result\"") })
            let objects: [[String: Any]]
            if outputMode == .json {
                let records = try #require(JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [[String: Any]])
                let resultRecord = try #require(records.first { $0["kind"] as? String == "discovery-result" })
                objects = try #require(resultRecord["objects"] as? [[String: Any]])
            } else {
                let json = try #require(JSONSerialization.jsonObject(with: Data(resultLine.utf8)) as? [String: Any])
                objects = try #require(json["objects"] as? [[String: Any]])
            }
            #expect(Set(objects.compactMap { $0["objectId"] as? String }) == ["primary-1", "related-1", "related-2"])
            #expect(objects.count == 3)
        }
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
        #expect(session.lastDiscoverRequest?.responseTimeout == .milliseconds(20))
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

        let completion = CompletionSignal()
        let runTask = Task {
            let result = await app.run()
            completion.signal(result)
        }
        defer {
            runTask.cancel()
            session.stop()
            session.finishPhases()
        }

        #expect(await waitForPhase(
            session.discoverStartedSignal(),
            description: "unlimited discovery request start"
        ))
        #expect(!session.stopped, "discovery should remain pending until interrupted")
        #expect(session.lastDiscoverRequest?.responseTimeout == nil)

        signalHandler.wasInterrupted = true
        switch await awaitBounded(
            completion,
            phase: "unlimited discovery interruption",
            onTimeout: { @MainActor in
                runTask.cancel()
                session.stop()
            }
        ) {
        case let .finished(result):
            #expect(result == .interrupted)
            #expect(session.stopped)
        case .timedOut:
            Issue.record("Unlimited discovery did not complete after interruption")
        }
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
    func invalidInspectorCoreTypeDoesNotInvokeDiscovery() async {
        let session = FakeInspectorSession()
        let app = InspectorDiscoverApplication(
            configuration: makeDiscoverConfig(coreType: "UnknownInspectorCoreType"),
            session: session,
            writeOutput: { _ in },
            writeDiagnostic: { _ in },
            timestamp: { "2026-07-31T00:00:00Z" },
            isTerminal: false
        )

        let result = await app.run()

        #expect(result == .invalidArguments(reason: "coreType must be a known core type: UnknownInspectorCoreType"))
        #expect(session.discoverCallCount == 0)
    }
}
