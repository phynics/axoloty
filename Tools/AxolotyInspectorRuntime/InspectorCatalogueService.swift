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
        started = true

        let advertiseStream = await session.advertiseEvents()
        let deadvertiseStream = await session.deadvertiseEvents()

        try await session.connect()

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
        streamTask?.cancel()
        session.stop()
        started = false
    }

    private func consumeStreams(
        advertise: AsyncStream<AdvertiseEventSnapshot>,
        deadvertise: AsyncStream<DeadvertiseEventSnapshot>,
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
