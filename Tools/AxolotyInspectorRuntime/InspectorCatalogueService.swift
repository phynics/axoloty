// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// Long-running service that observes Advertise/Deadvertise events and
/// updates an ``InspectorCatalogueStore``.
///
/// The service creates event streams before connecting to avoid the
/// subscription race. Stream consumers run in detached tasks so they
/// continue even if the caller suspends.
@MainActor
public final class InspectorCatalogueService {
    private let session: InspectorSession

    /// The catalogue store updated by this service.
    ///
    /// Exposed `nonisolated` so MCP handler closures (which run off the
    /// main actor) can read the store directly. Safe because the store is
    /// an actor that serializes its own access.
    public nonisolated let store: InspectorCatalogueStore
    private var streamTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var startGeneration = 0
    private var started = false

    /// Creates the service.
    /// - Parameters:
    ///   - session: The inspector session used to connect and observe events.
    ///   - namespace: The Coaty namespace being observed.
    public init(session: InspectorSession, namespace: String) {
        self.session = session
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.store = InspectorCatalogueStore(
            observedSince: formatter.string(from: Date()),
            namespace: namespace
        )
    }

    /// Connects to the broker and starts consuming event streams.
    public func start() async throws {
        guard !started else { return }

        if let startTask {
            try await startTask.value
            return
        }

        startGeneration += 1
        let generation = startGeneration
        let startTask = Task { @MainActor [self] in
            try await self.connectAndStartConsuming(generation: generation)
        }
        self.startTask = startTask
        defer {
            if self.startGeneration == generation {
                self.startTask = nil
            }
        }
        try await startTask.value
    }

    private func connectAndStartConsuming(generation: Int) async throws {

        let advertiseStream = await session.advertiseEvents()
        let deadvertiseStream = await session.deadvertiseEvents()

        try await session.connect()
        try Task.checkCancellation()
        guard startGeneration == generation else { return }
        started = true

        let store = self.store
        streamTask = Task.detached { [weak self] in
            await self?.consumeStreams(
                advertise: advertiseStream,
                deadvertise: deadvertiseStream,
                store: store
            )
        }
    }

    /// Stops the service and disconnects.
    public func stop() {
        startGeneration += 1
        startTask?.cancel()
        startTask = nil
        streamTask?.cancel()
        session.stop()
        started = false
    }

    /// Returns the session's current communication state.
    ///
    /// - Returns: The latest broker communication state.
    public func transportState() async -> InspectorTransportState {
        await session.transportState()
    }

    private func consumeStreams(
        advertise: AsyncStream<InspectorAdvertiseEvent>,
        deadvertise: AsyncStream<InspectorDeadvertiseEvent>,
        store: InspectorCatalogueStore
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await snapshot in advertise {
                    let object = InspectorObject(
                        objectId: snapshot.object.objectId,
                        coreType: snapshot.object.coreType.rawValue,
                        objectType: snapshot.object.objectType,
                        name: snapshot.object.name.isEmpty ? nil : snapshot.object.name,
                        sourceId: snapshot.sourceId
                    )
                    await store.apply(object)
                }
            }
            group.addTask {
                for await snapshot in deadvertise {
                    await store.remove(objectIds: snapshot.objectIds)
                }
            }
            await group.waitForAll()
        }
    }
}
