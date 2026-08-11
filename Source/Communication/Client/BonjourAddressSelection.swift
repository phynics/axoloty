// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A network address advertised by a Bonjour service.
enum BonjourAddressCandidate: Equatable, Sendable {
    case ipv4(String)
    case ipv6(String, scopeID: UInt32 = 0)
}

/// Chooses the address candidates that can be handed to the MQTT client.
enum BonjourAddressSelector {

    /// Returns IPv4 candidates first, followed by IPv6 candidates as fallback.
    ///
    /// An empty or otherwise unusable advertisement returns `nil` so callers
    /// can keep discovery running without handing an empty list to a consumer.
    static func select(from candidates: [BonjourAddressCandidate]) -> [String]? {
        let ipv4 = candidates.compactMap { candidate -> String? in
            guard case let .ipv4(address) = candidate, !address.isEmpty else {
                return nil
            }
            return address
        }
        let ipv6 = candidates.compactMap { candidate -> String? in
            guard case let .ipv6(address, scopeID) = candidate, !address.isEmpty else {
                return nil
            }
            return scopeID == 0 ? address : "\(address)%\(scopeID)"
        }
        let selected = ipv4 + ipv6
        return selected.isEmpty ? nil : selected
    }
}

/// A warning emitted when a Bonjour resolution cannot provide a broker address.
struct BonjourResolutionWarning: Equatable, Sendable {
    let message: String
    let metadata: [String: String]
}

/// Callbacks for the outcomes of a Bonjour resolution attempt.
struct BonjourResolutionCallbacks {
    let onWarning: (BonjourResolutionWarning) -> Void
    let onRetry: () -> Void
    let onReceive: ([String], Int) -> Void
}

/// Applies the common resolved-address policy used by the Bonjour resolver.
///
/// Keeping the policy separate from the platform-specific `NetService` delegate
/// gives tests a deterministic seam for the warning, retry, and delivery paths.
enum BonjourResolutionHandler {

    static let unusableAddressMessage = "Ignoring Bonjour service without usable addresses"

    static func handle(
        broker: String,
        candidates: [BonjourAddressCandidate]?,
        advertisedAddressCount: Int,
        port: Int,
        callbacks: BonjourResolutionCallbacks
    ) {
        guard let candidates else {
            callbacks.onWarning(BonjourResolutionWarning(message: unusableAddressMessage, metadata: [
                "broker": broker,
                "reason": "address data is missing",
            ]))
            callbacks.onRetry()
            return
        }

        guard let addresses = BonjourAddressSelector.select(from: candidates) else {
            callbacks.onWarning(BonjourResolutionWarning(message: unusableAddressMessage, metadata: [
                "broker": broker,
                "addressCount": "\(advertisedAddressCount)",
            ]))
            callbacks.onRetry()
            return
        }

        callbacks.onReceive(addresses, port)
    }
}
