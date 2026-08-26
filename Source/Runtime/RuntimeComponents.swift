// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

/// Package-only runtime component context used by first-party optional
/// products. The host remains the lifecycle owner; components may only submit
/// closed one-way operations through this context.
@_spi(AxolotyRuntimeAdapter)
public struct RuntimeComponentContext: Sendable {
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
    /// Emits a structured diagnostic from an optional component.
    public let diagnose: @Sendable (RuntimeDiagnostic) async -> Void
    /// Submits one closed response through the shared protocol processor.
    ///
    /// This remains SPI-only: optional first-party products can emit several
    /// correlated Resolve or Retrieve responses without adding a new protocol
    /// family or exposing the processor itself.
    public let respond: @Sendable (RuntimeResponse) async -> RuntimeReceipt

    /// Creates a package-only component context.
    ///
    /// - Parameters:
    ///   - namespace: The configured runtime namespace.
    ///   - sourceID: The runtime's stable source identity.
    ///   - publish: The closed operation submission function.
    ///   - request: The closed request submission function.
    ///   - cancelRequest: The correlation cancellation function.
    ///   - diagnose: The structured diagnostic sink.
    ///   - respond: The closed response submission function.
    public init(
        namespace: String,
        sourceID: UUID16,
        publish: @escaping @Sendable (RuntimeOneWayOperation) async -> RuntimeReceipt,
        request: @escaping @Sendable (RuntimeRequest) async -> RuntimeReceipt = { _ in .rejected(.notRunning(.closed)) },
        cancelRequest: @escaping @Sendable (UUID16) async -> Bool = { _ in false },
        diagnose: @escaping @Sendable (RuntimeDiagnostic) async -> Void = { _ in },
        respond: @escaping @Sendable (RuntimeResponse) async -> RuntimeReceipt = { _ in
            .rejected(.notRunning(.closed))
        }
    ) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.publish = publish
        self.request = request
        self.cancelRequest = cancelRequest
        self.diagnose = diagnose
        self.respond = respond
    }
}

/// Package-only registration for one bounded first-party runtime component.
///
/// Optional products use this seam to attach tasks to the existing runtime
/// lifecycle. It is intentionally SPI-only and is not a general plugin API.
@_spi(AxolotyRuntimeAdapter)
public struct RuntimeComponentRegistration: @unchecked Sendable {
    let start: @Sendable (RuntimeComponentContext) async -> Void
    let run: @Sendable (RuntimeComponentContext) async -> Void
    let stop: @Sendable (RuntimeComponentContext) async -> Void

    /// Creates a bounded first-party component registration.
    ///
    /// - Parameters:
    ///   - start: Invoked before the component run task starts.
    ///   - run: Invoked for the component's lifetime.
    ///   - stop: Invoked while the runtime is stopping.
    public init(
        start: @escaping @Sendable (RuntimeComponentContext) async -> Void = { _ in },
        run: @escaping @Sendable (RuntimeComponentContext) async -> Void,
        stop: @escaping @Sendable (RuntimeComponentContext) async -> Void = { _ in }
    ) {
        self.start = start
        self.run = run
        self.stop = stop
    }
}

extension RuntimeDefinition {
    /// Registers one bounded first-party component through the package-only
    /// runtime adapter seam.
    @_spi(AxolotyRuntimeAdapter)
    public mutating func registerRuntimeComponent(
        _ registration: RuntimeComponentRegistration
    ) throws {
        guard !sealed else {
            throw AxolotyError.runtime(code: .notStarted, reason: "the runtime definition is already sealed")
        }
        guard runtimeComponents.count < 4 else {
            throw AxolotyError.runtime(code: .capacityExceeded, reason: "runtime component capacity is full")
        }
        runtimeComponents.append(registration)
    }
}

extension RuntimeDefinition.Builder {
    /// Reserves a private correlation identity for an optional runtime component.
    ///
    /// The identity is derived from the definition nonce and a monotonic ordinal;
    /// callers receive no public correlation registry or lifecycle handle.
    @_spi(AxolotyRuntimeAdapter)
    public mutating func reserveRuntimeComponentCorrelationID() throws -> UUID16 {
        guard !definition.sealed else {
            throw AxolotyError.runtime(code: .notStarted, reason: "the runtime definition is already sealed")
        }
        definition.runtimeComponentCorrelationOrdinal &+= 1
        let ordinal = definition.runtimeComponentCorrelationOrdinal
        let base = definition.registryID.uuid.bytes
        return UUID16(bytes: (
            base.0, base.1, base.2, base.3, base.4, base.5, base.6, base.7,
            base.8, base.9, base.10, base.11,
            UInt8(truncatingIfNeeded: ordinal >> 24),
            UInt8(truncatingIfNeeded: ordinal >> 16),
            UInt8(truncatingIfNeeded: ordinal >> 8),
            UInt8(truncatingIfNeeded: ordinal)
        ))
    }
}

public extension RuntimeDefinition.Builder {
    /// Registers one bounded first-party component through the package-only
    /// runtime adapter seam.
    @_spi(AxolotyRuntimeAdapter)
    mutating func registerRuntimeComponent(
        _ registration: RuntimeComponentRegistration
    ) throws {
        try definition.registerRuntimeComponent(registration)
    }
}

extension ProtocolExecutor {
    func runtimeComponentContext() -> RuntimeComponentContext {
        RuntimeComponentContext(
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
            },
            respond: { [weak self] response in
                guard let self else {
                    return .rejected(.notRunning(.closed))
                }
                return await self.publish(
                    RuntimeOperation(response: response, sourceID: self.definition.sourceID),
                    nowMS: monotonicNowMS()
                )
            }
        )
    }

    func startRuntimeComponents(restarting: Bool = false) async {
        let context = runtimeComponentContext()
        if !restarting {
            runtimeComponentTasks.reserveCapacity(definition.runtimeComponents.count)
        }
        for registration in definition.runtimeComponents {
            await registration.start(context)
            guard !restarting else { continue }
            let task = Task { await registration.run(context) }
            runtimeComponentTasks.append(task)
        }
    }

    func stopRuntimeComponents() async {
        let context = runtimeComponentContext()
        let tasks = runtimeComponentTasks
        for task in tasks { task.cancel() }
        runtimeComponentTasks.removeAll(keepingCapacity: true)
        for task in tasks { await task.value }
        for registration in definition.runtimeComponents {
            await registration.stop(context)
        }
    }
}
