// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed lifecycle change suitable for async event consumers.
public struct ObjectLifecycleSnapshotInfo: Sendable, Equatable {
    /// Objects newly observed through Advertise events.
    public let added: [CoatyObjectSnapshot]?

    /// Objects observed again with changed properties.
    public let changed: [CoatyObjectSnapshot]?

    /// Objects removed through Deadvertise events.
    public let removed: [CoatyObjectSnapshot]?

    /// Creates a lifecycle snapshot.
    public init(
        added: [CoatyObjectSnapshot]? = nil,
        changed: [CoatyObjectSnapshot]? = nil,
        removed: [CoatyObjectSnapshot]? = nil
    ) {
        self.added = added
        self.changed = changed
        self.removed = removed
    }
}

extension ObjectLifecycleController {

    /// Observes object lifecycle changes by object type using immutable
    /// Advertise and Deadvertise snapshots.
    ///
    /// - Parameters:
    ///   - objectType: The object type to track.
    ///   - objectFilter: An optional filter over immutable object snapshots.
    /// - Returns: An async stream of lifecycle changes.
    /// - Throws: An invalid argument error when objectType is invalid.
    public func observeObjectLifecycleSnapshotsByObjectType(
        with objectType: String,
        objectFilter: (@Sendable (CoatyObjectSnapshot) -> Bool)? = nil
    ) async throws -> AsyncStream<ObjectLifecycleSnapshotInfo> {
        let advertiseStream: AsyncStream<AdvertiseEventSnapshot>
        if let coreType = CoreType.getCoreType(forObjectType: objectType) {
            advertiseStream = await communicationManager.observeAdvertiseStream(
                withCoreType: coreType
            )
        } else {
            advertiseStream = try await communicationManager.observeAdvertiseStream(
                withObjectType: objectType
            )
        }
        let deadvertiseStream = await communicationManager.observeDeadvertiseStream()
        let (stream, continuation) = AsyncStream<ObjectLifecycleSnapshotInfo>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        let registry = SnapshotLifecycleRegistry(
            objectType: objectType,
            objectFilter: objectFilter,
            continuation: continuation
        )
        let ready = LifecycleReadyBox(expected: 2)
        let taskBox = LifecycleTaskBox()
        let task = _Concurrency.Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var iterator = advertiseStream.makeAsyncIterator()
                    await ready.markReady()
                    while let snapshot = await iterator.next() {
                        await registry.handleAdvertise(snapshot)
                    }
                }
                group.addTask {
                    var iterator = deadvertiseStream.makeAsyncIterator()
                    await ready.markReady()
                    while let snapshot = await iterator.next() {
                        await registry.handleDeadvertise(snapshot)
                    }
                }
            }
        }
        await ready.waitUntilReady()
        await taskBox.set(task)
        continuation.onTermination = { _ in
            _Concurrency.Task {
                await taskBox.cancel()
            }
        }
        return stream
    }
}

private actor SnapshotLifecycleRegistry {
    private let objectType: String
    private let objectFilter: (@Sendable (CoatyObjectSnapshot) -> Bool)?
    private let continuation: AsyncStream<ObjectLifecycleSnapshotInfo>.Continuation
    private var objects: [String: CoatyObjectSnapshot] = [:]

    init(
        objectType: String,
        objectFilter: (@Sendable (CoatyObjectSnapshot) -> Bool)?,
        continuation: AsyncStream<ObjectLifecycleSnapshotInfo>.Continuation
    ) {
        self.objectType = objectType
        self.objectFilter = objectFilter
        self.continuation = continuation
    }

    func handleAdvertise(_ snapshot: AdvertiseEventSnapshot) {
        let object = snapshot.object
        guard object.objectType == objectType,
              objectFilter?(object) ?? true else {
            return
        }

        if let previous = objects[object.objectId] {
            guard previous != object else {
                return
            }
            objects[object.objectId] = object
            continuation.yield(ObjectLifecycleSnapshotInfo(changed: [object]))
        } else {
            objects[object.objectId] = object
            continuation.yield(ObjectLifecycleSnapshotInfo(added: [object]))
        }
    }

    func handleDeadvertise(_ snapshot: DeadvertiseEventSnapshot) {
        var removed: [CoatyObjectSnapshot] = []
        for objectId in snapshot.objectIds {
            let childIds = objects.values
                .filter { $0.parentObjectId == objectId }
                .map(\.objectId)
            for childId in childIds {
                if let child = objects.removeValue(forKey: childId) {
                    removed.append(child)
                }
            }
            if let object = objects.removeValue(forKey: objectId) {
                removed.append(object)
            }
        }
        if !removed.isEmpty {
            continuation.yield(ObjectLifecycleSnapshotInfo(removed: removed))
        }
    }
}

private actor LifecycleTaskBox {
    private var task: _Concurrency.Task<Void, Never>?

    func set(_ task: _Concurrency.Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

private actor LifecycleReadyBox {
    private let expected: Int
    private var readyCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func markReady() {
        readyCount += 1
        guard readyCount >= expected else {
            return
        }
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilReady() async {
        if readyCount >= expected {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
