// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs the legacy synchronous sensor API away from the MainActor.
internal final class SensorReadRequest: @unchecked Sendable {
    private let io: SensorIo
    private let bridge: SensorReadContinuation

    init(io: SensorIo, bridge: SensorReadContinuation) {
        self.io = io
        self.bridge = bridge
    }

    func start() {
        let request = self
        DispatchQueue.global(qos: .userInitiated).async {
            request.io.read { value in
                let ownedValue = RawJSONValue(any: value) ?? .null
                request.bridge.resume(ownedValue)
            }
        }
    }
}

/// Serializes sensor callback, deadline, and task-cancellation completion.
///
    /// The callback's untyped value is converted to ``RawJSONValue`` before it
    /// enters this bridge, so no arbitrary `Any` crosses the asynchronous
    /// boundary.
internal final class SensorReadContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private var pendingCompletion: SensorReadCompletion?
    private var continuation: CheckedContinuation<RawJSONValue, Error>?
    private var deadlineTask: Task<Void, Never>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<RawJSONValue, Error>) -> Bool {
        let result = lock.withLock { () -> (shouldInstall: Bool, pending: SensorReadCompletion?) in
            if didComplete {
                let pending = pendingCompletion
                pendingCompletion = nil
                return (false, pending)
            }
            self.continuation = continuation
            return (true, nil)
        }
        if let pending = result.pending {
            resume(continuation, with: pending)
        }
        return result.shouldInstall
    }

    func resume(_ value: RawJSONValue) {
        finish(.success(value))
    }

    func startDeadline(_ timeout: Duration, sensorId: CoatyUUID) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let task = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.finish(.failure(.runtime(code: .timedOut, reason: "Timed out waiting for sensor \(sensorId.string) read to complete")))
        }
        let keepTask = lock.withLock { () -> Bool in
            guard !didComplete else { return false }
            deadlineTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    func cancel(sensorId: CoatyUUID) {
        finish(.failure(.runtime(code: .cancelled, reason: "Sensor read was cancelled for \(sensorId.string)")))
    }

    private func finish(_ completion: SensorReadCompletion) {
        let (continuation, deadlineTask) = lock.withLock { () -> (CheckedContinuation<RawJSONValue, Error>?, Task<Void, Never>?) in
            guard !didComplete else { return (nil, nil) }
            didComplete = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                pendingCompletion = completion
            }
            let deadlineTask = self.deadlineTask
            self.deadlineTask = nil
            return (continuation, deadlineTask)
        }
        deadlineTask?.cancel()
        guard let continuation else { return }
        resume(continuation, with: completion)
    }

    private func resume(
        _ continuation: CheckedContinuation<RawJSONValue, Error>,
        with completion: SensorReadCompletion
    ) {
        switch completion {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private enum SensorReadCompletion {
    case success(RawJSONValue)
    case failure(AxolotyError)
}
