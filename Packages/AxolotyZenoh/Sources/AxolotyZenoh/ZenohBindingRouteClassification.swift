// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

extension ZenohBinding {
    /// Classifies a route using the active namespace and binding bounds.
    ///
    /// - Parameter route: A borrowed route valid only for this call.
    /// - Returns: `.coaty`, `.external`, or `.unrelated` for this binding.
    public func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        let namespace = Self.sessionRegistryLock.withLock { activeNamespace }
        return ZenohBindingSupport.classify(
            route,
            activeNamespace: namespace,
            maximumProfileKeyLength: configuration.maximumProfileKeyBytes
        )
    }
}
