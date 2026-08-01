// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// Internal event type for the discover event loop.
private enum DiscoverLoopEvent: Sendable {
    case response(ResponseEventSnapshot)
    case responsesExhausted
    case timeoutExpired
    case interrupted
}

/// Decoded payload of a Resolve response.
private struct ResolveResponsePayload: Decodable {
    let object: CoatyObjectSnapshot
}

/// Orchestrates active discovery: connects, publishes one Discover event,
/// collects Resolve responses, deduplicates by object ID, and emits a
/// finite discovery-result record.
@MainActor
public final class InspectorDiscoverApplication {
    private let configuration: InspectorConfiguration
    private let session: InspectorSession
    private let writeOutput: (String) -> Void
    private let writeDiagnostic: (String) -> Void
    private let timestamp: () -> String
    private let isTerminal: Bool
    private let signalHandler: InspectorSignalHandling?

    /// Creates the application.
    public init(
        configuration: InspectorConfiguration,
        session: InspectorSession,
        writeOutput: @escaping (String) -> Void,
        writeDiagnostic: @escaping (String) -> Void,
        timestamp: @escaping () -> String,
        isTerminal: Bool,
        signalHandler: InspectorSignalHandling? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.writeOutput = writeOutput
        self.writeDiagnostic = writeDiagnostic
        self.timestamp = timestamp
        self.isTerminal = isTerminal
        self.signalHandler = signalHandler
    }

    /// Runs the discovery and returns `nil` on success or an
    /// ``InspectorError`` on failure.
    public func run() async -> InspectorError? {
        guard case let .discover(cmd) = configuration.command else {
            return .invalidArguments(reason: "non-discover command passed to discover application")
        }

        let factory = InspectorRecordFactory(
            namespace: configuration.connection.namespace
        )
        let ndjsonFormatter = NDJSONFormatter()
        let humanFormatter = HumanFormatter()

        let resolvedOutput: InspectorOutputMode
        switch configuration.output {
        case .auto: resolvedOutput = isTerminal ? .human : .ndjson
        default: resolvedOutput = configuration.output
        }

        func emit(_ record: InspectorRecord) {
            let line: String
            switch resolvedOutput {
            case .human: line = humanFormatter.format(record)
            case .ndjson, .json: line = (try? ndjsonFormatter.format(record)) ?? ""
            case .auto: line = ""
            }
            if !line.isEmpty {
                writeOutput(line)
            }
        }

        do {
            try await session.connect()
        } catch let error as InspectorError {
            writeDiagnostic("error: \(error.userFriendlyMessage)")
            session.stop()
            return error
        } catch {
            let msg = String(describing: error)
            writeDiagnostic("error: \(msg)")
            session.stop()
            return .connectionUnavailable(reason: msg)
        }

        emit(factory.sessionStarted(
            timestamp: timestamp(),
            brokerHost: configuration.connection.host,
            brokerPort: configuration.connection.port
        ))

        let discoverEvent = makeDiscoverEvent(from: cmd)
        let responseStream = await session.discover(discoverEvent)

        let timeout = cmd.timeout.value ?? .seconds(10)

        var discoveredObjects: [String: InspectorObject] = [:]
        var timedOut = false

        let (eventStream, continuation) = AsyncStream.makeStream(of: DiscoverLoopEvent.self)

        let responseTask = _Concurrency.Task {
            var it = responseStream.makeAsyncIterator()
            while let response = await it.next() {
                continuation.yield(.response(response))
            }
            continuation.yield(.responsesExhausted)
        }

        let timerTask = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: timeout)
            continuation.yield(.timeoutExpired)
        }

        let signalTask = _Concurrency.Task {
            guard let handler = signalHandler else { return }
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(100))
                if handler.wasInterrupted {
                    continuation.yield(.interrupted)
                    return
                }
            }
        }

        var done = false
        var interrupted = false

        var eventIterator = eventStream.makeAsyncIterator()
        while !done, let event = await eventIterator.next() {
            switch event {
            case .response(let response):
                if let payload = response.decodePayload(ResolveResponsePayload.self) {
                    let object = payload.object
                    if discoveredObjects[object.objectId] == nil {
                        discoveredObjects[object.objectId] = InspectorObject(
                            objectId: object.objectId,
                            coreType: object.coreType.rawValue,
                            objectType: object.objectType,
                            name: object.name.isEmpty ? nil : object.name,
                            sourceId: response.sourceId
                        )
                    }
                }
            case .responsesExhausted:
                timedOut = true
                done = true
            case .timeoutExpired:
                timedOut = true
                done = true
            case .interrupted:
                interrupted = true
                done = true
            }
        }

        continuation.finish()
        responseTask.cancel()
        timerTask.cancel()
        signalTask.cancel()
        _ = await responseTask.value
        _ = await timerTask.value
        _ = await signalTask.value

        let objects = Array(discoveredObjects.values).sorted { $0.objectId < $1.objectId }

        let resultRecord = InspectorRecord(
            kind: .discoveryResult,
            timestamp: timestamp(),
            namespace: configuration.connection.namespace,
            timedOut: timedOut,
            objects: objects
        )
        emit(resultRecord)

        emit(factory.sessionEnded(timestamp: timestamp()))

        session.stop()

        if interrupted {
            return .interrupted
        }
        return nil
    }

    private func makeDiscoverEvent(from cmd: DiscoverCommand) -> DiscoverEvent {
        if let objectIdString = cmd.objectId,
           let uuid = CoatyUUID(uuidString: objectIdString) {
            return DiscoverEvent.with(objectId: uuid)
        }
        if let objectTypes = cmd.objectType.map({ [$0] }) {
            return DiscoverEvent.with(objectTypes: objectTypes)
        }
        if let coreTypeString = cmd.coreType,
           let coreType = CoreType(rawValue: coreTypeString) {
            return DiscoverEvent.with(coreTypes: [coreType])
        }
        return DiscoverEvent.with(coreTypes: [])
    }
}
