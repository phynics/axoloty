// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A dependency-ready check may overlap only when its owner has audited it for
/// concurrent execution.
struct AxolotyCheckSchedulingConfiguration: Sendable {
    /// Maximum number of active nodes allowed by the host resource budget.
    let maxConcurrentNodes: Int

    /// Creates a budget from the host limits and an optional operator override.
    ///
    /// The budget reserves two GiB per active node, uses the cgroup memory
    /// limit when available, and caps automatic fan-out at four nodes. Compiler
    /// and shared-scratch conflicts are enforced separately by node resources.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        availableMemoryBytes: UInt64? = nil
    ) {
        let processors = max(1, processorCount)
        let availableMemory = availableMemoryBytes ?? Self.availableMemoryBytes()
        let memorySlots = max(1, Int(min(UInt64(Int.max), availableMemory / (2 * 1_024 * 1_024 * 1_024))))
        let resourceLimit = max(1, min(4, processors, memorySlots))
        if let rawValue = environment["AXOLOTY_CHECK_CONCURRENCY"], !rawValue.isEmpty {
            guard let requested = Int(rawValue), requested > 0 else {
                maxConcurrentNodes = 1
                return
            }
            maxConcurrentNodes = min(resourceLimit, requested)
        } else {
            maxConcurrentNodes = resourceLimit
        }
    }

    private static func availableMemoryBytes() -> UInt64 {
        #if os(Linux)
        let cgroup = URL(fileURLWithPath: "/sys/fs/cgroup")
        if let limit = readUnsignedInteger(at: cgroup.appending(path: "memory.max")),
           let current = readUnsignedInteger(at: cgroup.appending(path: "memory.current")) {
            return limit > current ? min(limit - current, ProcessInfo.processInfo.physicalMemory) : 0
        }
        if let limit = readUnsignedInteger(at: cgroup.appending(path: "memory/memory.limit_in_bytes")),
           let current = readUnsignedInteger(at: cgroup.appending(path: "memory/memory.usage_in_bytes")) {
            return limit > current ? min(limit - current, ProcessInfo.processInfo.physicalMemory) : 0
        }
        #endif
        return ProcessInfo.processInfo.physicalMemory
    }

    private static func readUnsignedInteger(at url: URL) -> UInt64? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "max" else { return nil }
        return UInt64(value)
    }
}

/// A local reader/writer lock table for node resources.
struct AxolotyCheckResourceClaims {
    private var readers: [String: Int] = [:]
    private var writers: Set<String> = []

    func canAcquire(_ node: AxolotyCheckNode) -> Bool {
        let (shared, exclusive) = claims(for: node)
        return exclusive.allSatisfy { !writers.contains($0) && readers[$0, default: 0] == 0 }
            && shared.allSatisfy { !writers.contains($0) }
    }

    mutating func acquire(_ node: AxolotyCheckNode) {
        let (shared, exclusive) = claims(for: node)
        for resource in shared { readers[resource, default: 0] += 1 }
        writers.formUnion(exclusive)
    }

    mutating func release(_ node: AxolotyCheckNode) {
        let (shared, exclusive) = claims(for: node)
        for resource in shared {
            let remaining = readers[resource, default: 0] - 1
            if remaining == 0 {
                readers.removeValue(forKey: resource)
            } else {
                readers[resource] = remaining
            }
        }
        writers.subtract(exclusive)
    }

    private func claims(for node: AxolotyCheckNode) -> (shared: Set<String>, exclusive: Set<String>) {
        let declared = Set(node.resources)
        let shared = Set(node.sharedResources).intersection(declared)
        var exclusive = declared.subtracting(shared)
        if let lane = node.lane {
            exclusive.insert("@lane:\(lane)")
        }
        return (shared, exclusive)
    }
}

struct AxolotyCheckCompletion: Sendable {
    let node: String
    let result: AxolotyCheckResult
}

// @unchecked: the lock protects the completion queue; values crossing it are Sendable.
final class AxolotyCheckCompletionMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var completions: [AxolotyCheckCompletion] = []

    func append(_ completion: AxolotyCheckCompletion) {
        condition.lock()
        completions.append(completion)
        condition.signal()
        condition.unlock()
    }

    func take() -> AxolotyCheckCompletion {
        condition.lock()
        defer { condition.unlock() }
        while completions.isEmpty { condition.wait() }
        return completions.removeFirst()
    }
}

// @unchecked: delivery serializes the caller-supplied sink, including timer callbacks.
final class AxolotyCheckEventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (AxolotyCheckExecutionEvent) -> Void

    init(sink: @escaping @Sendable (AxolotyCheckExecutionEvent) -> Void) {
        self.sink = sink
    }

    func send(_ event: AxolotyCheckExecutionEvent) {
        lock.lock()
        sink(event)
        lock.unlock()
    }
}
