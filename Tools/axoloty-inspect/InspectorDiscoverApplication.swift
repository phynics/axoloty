// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// Decoded payload of a Resolve response.
private struct ResolveResponsePayload: Decodable {
    let object: CoatyObjectSnapshot
}

/// Orchestrates active discovery: connects, publishes one Discover event,
/// collects Resolve responses, deduplicates by object ID, and emits a
/// finite discovery-result record.
@MainActor
final class InspectorDiscoverApplication {
    private let configuration: InspectorConfiguration
    private let session: InspectorSession
    private let writeOutput: (String) -> Void
    private let writeDiagnostic: (String) -> Void
    private let timestamp: () -> String
    private let isTerminal: Bool
    private let signalHandler: InspectorSignalHandling?

    init(
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

    func run() async -> InspectorError? {
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
        let inactivityWindow: Duration = .seconds(1)

        var discoveredObjects: [String: InspectorObject] = [:]
        var timedOut = false

        let (eventStream, continuation) = AsyncStream.makeStream(of: ResponseEvent?.self)

        let responseTask = Task {
            var it = responseStream.makeAsyncIterator()
            while let response = await it.next() {
                continuation.yield(response)
            }
            continuation.yield(nil)
        }

        let timerTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }

        let signalTask = Task {
            guard let handler = signalHandler else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if handler.wasInterrupted {
                    continuation.yield(nil)
                    return
                }
            }
        }

        var lastResponseTime = ContinuousClock.now
        var done = false
        var interrupted = false

        var eventIterator = eventStream.makeAsyncIterator()
        while !done, let event = await eventIterator.next() {
            if let handler = signalHandler, handler.wasInterrupted {
                interrupted = true
                done = true
                break
            }

            guard let response = event else {
                if !discoveredObjects.isEmpty {
                    let now = ContinuousClock.now
                    if now - lastResponseTime < inactivityWindow {
                        continue
                    }
                }
                timedOut = true
                done = true
                break
            }

            lastResponseTime = ContinuousClock.now

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
