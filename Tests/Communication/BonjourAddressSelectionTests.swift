// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty

#if canImport(Darwin)
import Darwin
import Foundation
#endif

@Suite
struct BonjourAddressSelectionTests {

    @Test
    func emptyResolutionIsRejected() {
        #expect(BonjourAddressSelector.select(from: []) == nil)
    }

    @Test
    func ipv4ResolutionReturnsIPv4Candidates() {
        let candidates: [BonjourAddressCandidate] = [
            .ipv4("192.0.2.1"),
            .ipv4("192.0.2.2"),
        ]

        #expect(BonjourAddressSelector.select(from: candidates) == ["192.0.2.1", "192.0.2.2"])
    }

    @Test
    func ipv6ResolutionReturnsIPv6Candidates() {
        let candidates: [BonjourAddressCandidate] = [
            .ipv6("2001:db8::1"),
            .ipv6("2001:db8::2"),
        ]

        #expect(BonjourAddressSelector.select(from: candidates) == ["2001:db8::1", "2001:db8::2"])
    }

    @Test
    func scopedIPv6ResolutionPreservesScopeIdentifier() {
        let candidates: [BonjourAddressCandidate] = [
            .ipv6("fe80::1", scopeID: 3),
        ]

        #expect(BonjourAddressSelector.select(from: candidates) == ["fe80::1%3"])
    }

#if canImport(Darwin)
    @Test
    func scopedIPv6SockaddrPreservesScopeIdentifier() {
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_scope_id = 3

        var addressBytes = [UInt8](repeating: 0, count: 16)
        addressBytes[0] = 0xfe
        addressBytes[1] = 0x80
        addressBytes[15] = 1
        withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { destination in
            destination.copyBytes(from: addressBytes)
        }

        let data = Data(bytes: &socketAddress, count: MemoryLayout<sockaddr_in6>.size)
        let resolver = BonjourResolver()

        #expect(resolver.resolveAddressCandidate(address: data) == .ipv6("fe80::1", scopeID: 3))
    }
#endif

    @Test
    func ipv4CandidatesPrecedeIPv6FallbackCandidates() {
        let candidates: [BonjourAddressCandidate] = [
            .ipv6("2001:db8::2"),
            .ipv4("192.0.2.1"),
            .ipv6("2001:db8::3"),
        ]

        #expect(BonjourAddressSelector.select(from: candidates) == [
            "192.0.2.1",
            "2001:db8::2",
            "2001:db8::3",
        ])
    }

    @Test
    func missingAddressAdvertisementLogsAndRetriesWithoutDelivery() {
        var warnings = [BonjourResolutionWarning]()
        var retryCount = 0
        var deliveries = [[String]]()

        BonjourResolutionHandler.handle(
            broker: "broker.local",
            candidates: nil,
            advertisedAddressCount: 0,
            port: 1883,
            callbacks: BonjourResolutionCallbacks(
                onWarning: { warnings.append($0) },
                onRetry: { retryCount += 1 },
                onReceive: { addresses, _ in deliveries.append(addresses) }
            )
        )

        #expect(warnings == [BonjourResolutionWarning(
            message: BonjourResolutionHandler.unusableAddressMessage,
            metadata: [
                "broker": "broker.local",
                "reason": "address data is missing",
            ]
        )])
        #expect(retryCount == 1)
        #expect(deliveries.isEmpty)
    }

    @Test
    func emptyAddressAdvertisementLogsAndRetriesWithoutDelivery() {
        var warnings = [BonjourResolutionWarning]()
        var retryCount = 0
        var deliveries = [[String]]()

        BonjourResolutionHandler.handle(
            broker: "broker.local",
            candidates: [],
            advertisedAddressCount: 0,
            port: 1883,
            callbacks: BonjourResolutionCallbacks(
                onWarning: { warnings.append($0) },
                onRetry: { retryCount += 1 },
                onReceive: { addresses, _ in deliveries.append(addresses) }
            )
        )

        #expect(warnings == [BonjourResolutionWarning(
            message: BonjourResolutionHandler.unusableAddressMessage,
            metadata: [
                "broker": "broker.local",
                "addressCount": "0",
            ]
        )])
        #expect(retryCount == 1)
        #expect(deliveries.isEmpty)
    }
}
