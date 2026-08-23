//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  BonjourResolver.swift
//  Axoloty
//
//

import Foundation

// `NetService`/`NetServiceBrowser` are only available on Apple platforms
// (they are not part of swift-corelibs-foundation on Linux). This is the
// only Bonjour-specific implementation of `ServiceDiscovery`; platforms
// without Darwin simply do not compile or link this type.
#if canImport(Darwin)

import Darwin

/// This class provides Bonjour-based broker discovery and calls
/// its delegate when it has found new services.
class BonjourResolver: NSObject, ServiceDiscovery {

    // MARK: - Attributes.

    private let log = LogManager.logger(.mqtt)
    private let browser = NetServiceBrowser()
    private var brokerService: NetService?
    var delegate: ServiceDiscoveryDelegate?

    override init() {
        super.init()
 
        // Set NetService browser delegate.
        browser.delegate = self
    }
 
    // MARK: - Helper methods.
 
    public func startDiscovery() {
        stopDiscovery()
 
        browser.searchForServices(ofType: BonjourConfiguration.serviceType, inDomain: BonjourConfiguration.serviceDomain)
 
    }
 
    public func stopDiscovery() {
        browser.stop()
    }
 
}

// MARK: - NetServiceBrowserDelegate extension.

extension BonjourResolver: NetServiceBrowserDelegate {
 
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {

        log.debug("Did find net service", metadata: ["broker": .string(service.name)])

        // Has to be saved here, otherwise we lose reference and cannot resolve.
        brokerService = service

        // Add delegate for resolving later.
        brokerService?.delegate = self

        // Starting the service resolve.
        service.resolve(withTimeout: 5)

    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log.warning("Did not search net service", metadata: [
            "error": .string(errorDict.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")),
        ])
    }
}

// MARK: - NetServiceDelegate extension.

extension BonjourResolver: NetServiceDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        log.debug("Did remove net service", metadata: ["broker": .string(service.name)])
    }

    func netServiceDidResolveAddress(_ sender: NetService) {

        log.debug("Did resolve net service address", metadata: ["broker": .string(sender.name)])

        let advertisedAddresses = sender.addresses
        let candidates = advertisedAddresses.map { resolveAddressCandidates(addresses: $0) }
        BonjourResolutionHandler.handle(
            broker: sender.name,
            candidates: candidates,
            advertisedAddressCount: advertisedAddresses?.count ?? 0,
            port: sender.port,
            callbacks: BonjourResolutionCallbacks(
                onWarning: { [log] warning in
                    var metadata = warning.metadata
                    metadata["message"] = warning.message
                    log.warning("Bonjour resolution warning", metadata: metadata.mapValues { .string($0) })
                },
                onRetry: { [weak self] in
                    self?.startDiscovery()
                },
                onReceive: { [weak self] addresses, port in
                    self?.delegate?.didReceiveService(addresses: addresses, port: port)
                }
            )
        )
    }

    // MARK: - Address parsing methods.

    /// Converts the platform-specific Bonjour address data into portable
    /// address candidates. Invalid or unsupported entries are ignored.
    private func resolveAddressCandidates(addresses: [Data]) -> [BonjourAddressCandidate] {
        addresses.compactMap { address in
            resolveAddressCandidate(address: address)
        }
    }

    func resolveAddressCandidate(address: Data) -> BonjourAddressCandidate? {
        let copyLength = min(address.count, MemoryLayout<sockaddr_storage>.size)
        guard copyLength >= MemoryLayout<sa_family_t>.size else {
            return nil
        }

        var storage = sockaddr_storage()
        (address as NSData).getBytes(&storage, length: copyLength)

        switch Int32(storage.ss_family) {
        case AF_INET:
            guard address.count >= MemoryLayout<sockaddr_in>.size else {
                return nil
            }
            return withUnsafePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addressPointer in
                    var address = addressPointer.pointee.sin_addr
                    guard let string = withUnsafePointer(to: &address, { addressPointer in
                        stringAddress(
                            family: AF_INET,
                            address: UnsafeRawPointer(addressPointer),
                            bufferLength: Int(INET_ADDRSTRLEN)
                        )
                    }) else {
                        return nil
                    }
                    return .ipv4(string)
                }
            }
        case AF_INET6:
            guard address.count >= MemoryLayout<sockaddr_in6>.size else {
                return nil
            }
            return withUnsafePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addressPointer in
                    var address = addressPointer.pointee.sin6_addr
                    guard let string = withUnsafePointer(to: &address, { addressPointer in
                        stringAddress(
                            family: AF_INET6,
                            address: UnsafeRawPointer(addressPointer),
                            bufferLength: Int(INET6_ADDRSTRLEN)
                        )
                    }) else {
                        return nil
                    }
                    return .ipv6(string, scopeID: addressPointer.pointee.sin6_scope_id)
                }
            }
        default:
            return nil
        }
    }

    private func stringAddress(family: Int32, address: UnsafeRawPointer, bufferLength: Int) -> String? {
        guard bufferLength > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: bufferLength)
        let converted = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Bool in
            guard let destination = bufferPointer.baseAddress else {
                return false
            }
            return inet_ntop(family, address, destination, socklen_t(bufferPointer.count)) != nil
        }
        guard converted else {
            return nil
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else {
            return nil
        }
        return String(bytes: bytes, encoding: .ascii)
    }

}

#endif
