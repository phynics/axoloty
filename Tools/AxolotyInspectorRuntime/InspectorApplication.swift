// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// Internal event type for the merged event loop.
private enum ApplicationEvent: Sendable {
    case advertise(AdvertiseEventSnapshot)
    case deadvertise(DeadvertiseEventSnapshot)
    case durationExpired
    case interrupted
    case streamEnded
}

/// The outcomes that can win the initial connection race.
private enum InitialConnectEvent: Sendable {
    case connected
    case interrupted
}

/// Orchestrates the passive catalogue: connects a session, consumes
/// Advertise and Deadvertise streams, maintains an object catalogue,
/// and emits formatted output records.
///
/// All dependencies are injected for testability: the session can be
/// faked, output/diagnostic sinks are closures, and the timestamp
/// provider is injectable.
@MainActor
public final class InspectorApplication {
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

    /// Runs the catalogue observation and returns `nil` on success or an
    /// ``InspectorError`` on failure.
    public func run() async -> InspectorError? {
        guard case let .catalog(cmd) = configuration.command else {
            return .invalidArguments(reason: "non-catalog command passed to catalog application")
        }

        let filter = ObjectCatalogueFilter(
            coreType: cmd.coreType,
            objectType: cmd.objectType,
            objectId: cmd.objectId,
            sourceId: cmd.sourceId
        )
        let reducer = ObjectCatalogueReducer(filter: filter)
        let factory = InspectorRecordFactory(
            namespace: configuration.connection.namespace,
            includePayload: cmd.full,
            includePrivateData: cmd.includePrivateData
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
            case .human:
                line = humanFormatter.format(record)
            case .ndjson, .json:
                line = (try? ndjsonFormatter.format(record)) ?? ""
            case .auto:
                line = ""
            }
            if !line.isEmpty {
                writeOutput(line)
            }
        }

        let advertiseStream = await session.advertiseEvents()
        let deadvertiseStream = await session.deadvertiseEvents()

        let initialConnectEvent: InitialConnectEvent
        do {
            initialConnectEvent = try await connectWhileMonitoringSignals()
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

        if case .interrupted = initialConnectEvent {
            return .interrupted
        }

        emit(factory.sessionStarted(
            timestamp: timestamp(),
            brokerHost: configuration.connection.host,
            brokerPort: configuration.connection.port
        ))

        let (eventStream, continuation) = AsyncStream.makeStream(of: ApplicationEvent.self)

        let advertTask = Task {
            var it = advertiseStream.makeAsyncIterator()
            while let snapshot = await it.next() {
                continuation.yield(.advertise(snapshot))
            }
            continuation.yield(.streamEnded)
        }

        let deadvertTask = Task {
            var it = deadvertiseStream.makeAsyncIterator()
            while let snapshot = await it.next() {
                continuation.yield(.deadvertise(snapshot))
            }
            continuation.yield(.streamEnded)
        }

        let timerTask = Task {
            if let duration = cmd.duration.value {
                try? await Task.sleep(for: duration)
                continuation.yield(.durationExpired)
            }
        }

        let signalTask = Task {
            guard let handler = signalHandler else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if handler.wasInterrupted {
                    continuation.yield(.interrupted)
                    return
                }
            }
        }

        var catalogue = ObjectCatalogue()
        var result: InspectorError?
        var done = false

        var eventIterator = eventStream.makeAsyncIterator()
        while !done, let event = await eventIterator.next() {
            switch event {
            case .advertise(let snapshot):
                let object = Self.convert(snapshot, cmd: cmd)
                let (newCat, mutation) = reducer.reduceAdvertise(object, into: catalogue)
                catalogue = newCat
                if let mutation, let record = factory.record(for: mutation, timestamp: timestamp()) {
                    emit(record)
                }
            case .deadvertise(let snapshot):
                let results = reducer.reduceDeadvertise(snapshot.objectIds, into: catalogue)
                for (newCat, mutation) in results {
                    catalogue = newCat
                    if let record = factory.record(for: mutation, timestamp: timestamp()) {
                        emit(record)
                    }
                }
            case .durationExpired:
                done = true
            case .interrupted:
                result = .interrupted
                done = true
            case .streamEnded:
                result = .connectionUnavailable(reason: "event stream ended unexpectedly")
                done = true
            }
        }

        continuation.finish()
        advertTask.cancel()
        deadvertTask.cancel()
        timerTask.cancel()
        signalTask.cancel()
        _ = await advertTask.value
        _ = await deadvertTask.value
        _ = await timerTask.value
        _ = await signalTask.value
        emit(factory.sessionEnded(timestamp: timestamp()))

        session.stop()
        return result
    }

    private func connectWhileMonitoringSignals() async throws -> InitialConnectEvent {
        let connectOperation: @MainActor @Sendable () async throws -> Void = { [session] in
            try await session.connect()
        }

        let signalOperation: (@MainActor @Sendable () async throws -> InitialConnectEvent)?
        if let handler = signalHandler {
            signalOperation = { @MainActor [handler] in
                while true {
                    try Task.checkCancellation()
                    if handler.wasInterrupted {
                        return .interrupted
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            signalOperation = nil
        }

        return try await withThrowingTaskGroup(of: InitialConnectEvent.self) { group in
            group.addTask {
                try await connectOperation()
                return .connected
            }

            if let signalOperation {
                group.addTask {
                    try await signalOperation()
                }
            }

            guard let event = try await group.next() else {
                throw InspectorError.connectionUnavailable(
                    reason: "connection attempt ended without an outcome"
                )
            }

            if case .interrupted = event {
                session.stop()
            }
            group.cancelAll()
            return event
        }
    }

    private static func convert(
        _ snapshot: AdvertiseEventSnapshot,
        cmd: CatalogCommand
    ) -> InspectorObject {
        InspectorObject(
            objectId: snapshot.object.objectId,
            coreType: snapshot.object.coreType.rawValue,
            objectType: snapshot.object.objectType,
            name: snapshot.object.name.isEmpty ? nil : snapshot.object.name,
            sourceId: snapshot.sourceId,
            payload: cmd.full ? snapshot.object.payload : nil,
            privateData: cmd.includePrivateData ? snapshot.privateData : nil
        )
    }
}
