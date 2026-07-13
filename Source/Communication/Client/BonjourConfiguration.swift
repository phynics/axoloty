//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  BonjourConfiguration.swift
//  CoatySwift
//
//

import Foundation

// Only consumed by `BonjourResolver`, which is itself Apple-only. See
// `ServiceDiscovery.swift` for the platform-independent seam.
#if canImport(Darwin)

class BonjourConfiguration {
    static let defaultBrokerName = "Coaty MQTT Broker"
    static let serviceType = "_coaty-mqtt._tcp."
    static let serviceDomain = "local."
}

#endif
