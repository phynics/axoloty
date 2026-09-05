// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

/// Package-only runtime module context used by first-party optional
/// products. The host remains the lifecycle owner; modules may only submit
/// closed one-way operations through this context.
package struct RuntimeModuleContext: Sendable {
    /// The configured runtime namespace.
    public let namespace: String
    /// The runtime's stable source identity.
    public let sourceID: UUID16
    /// Submits one closed one-way operation through the existing executor.
    public let publish: @Sendable (RuntimeOneWayOperation) async -> RuntimeReceipt
    /// Starts one bounded request through the existing executor.
    public let request: @Sendable (RuntimeRequest) async -> RuntimeReceipt
    /// Cancels one outstanding request correlation.
    public let cancelRequest: @Sendable (UUID16) async -> Bool
    /// Emits a structured diagnostic from an optional module.
    public let diagnose: @Sendable (RuntimeDiagnostic) async -> Void

    /// Creates a package-only module context.
    ///
    /// - Parameters:
    ///   - namespace: The configured runtime namespace.
    ///   - sourceID: The runtime's stable source identity.
    ///   - publish: The closed operation submission function.
    ///   - request: The closed request submission function.
    ///   - cancelRequest: The correlation cancellation function.
    ///   - diagnose: The structured diagnostic sink.
    public init(
        namespace: String,
        sourceID: UUID16,
        publish: @escaping @Sendable (RuntimeOneWayOperation) async -> RuntimeReceipt,
        request: @escaping @Sendable (RuntimeRequest) async -> RuntimeReceipt = { _ in .rejected(.notRunning(.closed)) },
        cancelRequest: @escaping @Sendable (UUID16) async -> Bool = { _ in false },
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void = { _ in }
    ) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.publish = publish
        self.request = request
        self.cancelRequest = cancelRequest
        self.diagnose = diagnose
    }
}

/// Package-only registration for one bounded first-party runtime module.
///
/// Optional products use this seam to attach tasks to the existing runtime
/// lifecycle. It is intentionally SPI-only and is not a general plugin API.
package struct RuntimeModuleRegistration: @unchecked Sendable {
    let start: @Sendable (RuntimeModuleContext) async -> Void
    let run: @Sendable (RuntimeModuleContext) async -> Void
    let stop: @Sendable (RuntimeModuleContext) async -> Void

    /// Creates a bounded first-party module registration.
    ///
    /// - Parameters:
    ///   - start: Invoked before the module run task starts.
    ///   - run: Invoked for the module's lifetime.
    ///   - stop: Invoked while the runtime is stopping.
    public init(
        start: @escaping @Sendable (RuntimeModuleContext) async -> Void = { _ in },
        run: @escaping @Sendable (RuntimeModuleContext) async -> Void,
        stop: @escaping @Sendable (RuntimeModuleContext) async -> Void = { _ in }
    ) {
        self.start = start
        self.run = run
        self.stop = stop
    }
}

extension RuntimeBuilder {
    /// Registers one bounded first-party module through the package-only
    /// runtime adapter seam.
    ///
    /// - Parameters:
    ///   - registration: The module lifecycle callbacks.
    ///   - key: The stable internal module key.
    /// - Throws: ``AxolotyError`` when the key is invalid, duplicated, or at capacity.
    package mutating func registerRuntimeModule(
        _ registration: RuntimeModuleRegistration,
        key: String
    ) throws {
        try commitRuntimeModule(key: key, registration: registration)
    }

    /// Reserves a private correlation identity for an optional runtime module.
    ///
    /// The identity is derived from the definition nonce and a monotonic ordinal;
    /// callers receive no public correlation registry or lifecycle handle.
    ///
    /// - Returns: A correlation identity reserved within the current builder draft.
    /// - Throws: ``AxolotyError`` if the builder cannot commit the reservation.
    package mutating func reserveRuntimeModuleCorrelationID() throws -> UUID16 {
        return try commit { $0.reserveModuleCorrelationID() }
    }
}

private extension RuntimeBuilder {
    mutating func commitRuntimeModule(key: String, registration: RuntimeModuleRegistration) throws {
        guard !key.isEmpty, key.utf8.count <= 64 else {
            throw AxolotyError.invalidArgument(argument: "key", reason: "runtime module key must contain 1...64 UTF-8 bytes")
        }
        try commit { draft in
            guard !draft.moduleKeys.contains(key) else {
                throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime module key is already registered")
            }
            guard draft.modules.count < 4 else {
                throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime module capacity is full")
            }
            draft.moduleKeys.insert(key)
            draft.modules.append(registration)
        }
    }
}

extension ProtocolExecutor {
    func runtimeModuleContext() -> RuntimeModuleContext {
        RuntimeModuleContext(
            namespace: definition.namespace,
            sourceID: definition.sourceID,
            publish: { [weak self] operation in
                guard let self else {
                    return .rejected(.notRunning(.closed))
                }
                return await self.publish(
                    RuntimeOperation(oneWay: operation, sourceID: self.definition.sourceID),
                    nowMS: monotonicNowMS()
                )
            },
            request: { [weak self] request in
                guard let self else {
                    return .rejected(.notRunning(.closed))
                }
                return await self.publish(
                    RuntimeOperation(request: request, sourceID: self.definition.sourceID),
                    nowMS: monotonicNowMS()
                )
            },
            cancelRequest: { [weak self] correlationID in
                guard let self else { return false }
                return await self.cancel(correlationID: correlationID)
            },
            diagnose: { [weak self] diagnostic in
                guard let self else { return }
                await self.emit(diagnostic)
            }
        )
    }

    func startRuntimeModules(restarting: Bool = false) async {
        let context = runtimeModuleContext()
        if !restarting {
            runtimeModuleTasks.reserveCapacity(definition.registrations.modules.count)
        }
        for registration in definition.registrations.modules {
            await registration.start(context)
            guard !restarting else { continue }
            let task = Task { await registration.run(context) }
            runtimeModuleTasks.append(task)
        }
    }

    func stopRuntimeModules() async {
        let context = runtimeModuleContext()
        let tasks = runtimeModuleTasks
        for task in tasks { task.cancel() }
        runtimeModuleTasks.removeAll(keepingCapacity: true)
        for registration in definition.registrations.modules {
            await registration.stop(context)
        }
        for task in tasks { await task.value }
    }
}
