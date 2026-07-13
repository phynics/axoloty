// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  ServiceDiscovery.swift
//  Axoloty
//
//

import Foundation

/// Receives broker candidates found by a `ServiceDiscovery` implementation.
protocol ServiceDiscoveryDelegate {
    func didReceiveService(addresses: [String], port: Int)
}

/// Seam for broker discovery mechanisms (e.g. Bonjour/mDNS).
///
/// This protocol captures the minimal surface consumed by
/// `MQTTNIOClient`: start/stop a discovery process and report resolved
/// broker candidates back via `delegate`. Concrete implementations may be
/// platform-specific (see `BonjourResolver`, available on Apple platforms
/// only); platforms without an implementation simply have none available,
/// and requesting discovery there is reported as an explicit error rather
/// than silently doing nothing.
protocol ServiceDiscovery: AnyObject {

    /// Delegate notified when a broker candidate has been found and resolved.
    var delegate: ServiceDiscoveryDelegate? { get set }

    /// Starts (or restarts) the discovery process.
    func startDiscovery()

    /// Stops the discovery process.
    func stopDiscovery()
}
