// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

import AxolotyZenoh
import AxolotyZenohCore

@Suite("Zenoh binding configuration")
struct ZenohBindingConfigurationTests {
    @Test("accepts the client configuration fields and supported boundaries")
    func acceptsConfigurationAndBoundaries() throws(ZenohBindingConfigurationError) {
        let configuration = try ZenohBindingConfiguration(
            mode: .client,
            connectEndpoint: String(repeating: "x", count: 512),
            maximumProfileKeyBytes: 256,
            maximumExternalRoutes: 64,
            receiveQueueCapacity: 4,
            receiveKeyCapacity: 256,
            receivePayloadCapacity: 2048
        )

        #expect(configuration.mode == .client)
        #expect(configuration.connectEndpoint.utf8.count == 512)
        #expect(configuration.maximumProfileKeyBytes == 256)
        #expect(configuration.maximumExternalRoutes == 64)
        #expect(configuration.receiveQueueCapacity == 4)
        #expect(configuration.receiveKeyCapacity == 256)
        #expect(configuration.receivePayloadCapacity == 2048)

        let minimums = try ZenohBindingConfiguration(
            connectEndpoint: "x",
            maximumProfileKeyBytes: 1,
            maximumExternalRoutes: 1,
            receiveQueueCapacity: 1,
            receiveKeyCapacity: 1,
            receivePayloadCapacity: 1
        )
        #expect(minimums.connectEndpoint == "x")
        #expect(minimums.maximumProfileKeyBytes == 1)
        #expect(minimums.maximumExternalRoutes == 1)
        #expect(minimums.receiveQueueCapacity == 1)
        #expect(minimums.receiveKeyCapacity == 1)
        #expect(minimums.receivePayloadCapacity == 1)
    }

    @Test("defaults only to client router settings and bounded receive capacities")
    func defaultsStayWithinMVP() throws(ZenohBindingConfigurationError) {
        let configuration = try ZenohBindingConfiguration()

        #expect(configuration.mode == .client)
        #expect(configuration.connectEndpoint == "tcp/127.0.0.1:7447")
        #expect(configuration.maximumProfileKeyBytes == 256)
        #expect(configuration.maximumExternalRoutes == 64)
        #expect(configuration.receiveQueueCapacity == 4)
        #expect(configuration.receiveKeyCapacity == ZenohFrameStorage.keyCapacity)
        #expect(configuration.receivePayloadCapacity == ZenohFrameStorage.payloadCapacity)
    }

    @Test("rejects invalid endpoint bytes and endpoint length")
    func rejectsInvalidEndpoints() {
        #expect(throws: ZenohBindingConfigurationError.invalidConnectEndpoint) {
            try ZenohBindingConfiguration(connectEndpoint: "")
        }
        #expect(throws: ZenohBindingConfigurationError.invalidConnectEndpoint) {
            try ZenohBindingConfiguration(connectEndpoint: String(repeating: "x", count: 513))
        }
        #expect(throws: ZenohBindingConfigurationError.invalidConnectEndpoint) {
            try ZenohBindingConfiguration(connectEndpoint: "tcp/router\n")
        }
        #expect(throws: ZenohBindingConfigurationError.invalidConnectEndpoint) {
            try ZenohBindingConfiguration(connectEndpoint: "tcp/\"router\"")
        }
        #expect(throws: ZenohBindingConfigurationError.invalidConnectEndpoint) {
            try ZenohBindingConfiguration(connectEndpoint: "tcp/router\\path")
        }
    }

    @Test("reports each invalid capacity with its typed error")
    func reportsSpecificCapacityErrors() {
        #expect(throws: ZenohBindingConfigurationError.maximumProfileKeyBytesOutOfRange) {
            try ZenohBindingConfiguration(maximumProfileKeyBytes: 0)
        }
        #expect(throws: ZenohBindingConfigurationError.maximumProfileKeyBytesOutOfRange) {
            try ZenohBindingConfiguration(maximumProfileKeyBytes: 257)
        }
        #expect(throws: ZenohBindingConfigurationError.maximumExternalRoutesOutOfRange) {
            try ZenohBindingConfiguration(maximumExternalRoutes: 0)
        }
        #expect(throws: ZenohBindingConfigurationError.maximumExternalRoutesOutOfRange) {
            try ZenohBindingConfiguration(maximumExternalRoutes: 65)
        }
        #expect(throws: ZenohBindingConfigurationError.receiveQueueCapacityOutOfRange) {
            try ZenohBindingConfiguration(receiveQueueCapacity: 0)
        }
        #expect(throws: ZenohBindingConfigurationError.receiveQueueCapacityOutOfRange) {
            try ZenohBindingConfiguration(receiveQueueCapacity: 5)
        }
        #expect(throws: ZenohBindingConfigurationError.receiveKeyCapacityOutOfRange) {
            try ZenohBindingConfiguration(receiveKeyCapacity: 0)
        }
        #expect(throws: ZenohBindingConfigurationError.receiveKeyCapacityOutOfRange) {
            try ZenohBindingConfiguration(receiveKeyCapacity: 257)
        }
        #expect(throws: ZenohBindingConfigurationError.receivePayloadCapacityOutOfRange) {
            try ZenohBindingConfiguration(receivePayloadCapacity: 0)
        }
        #expect(throws: ZenohBindingConfigurationError.receivePayloadCapacityOutOfRange) {
            try ZenohBindingConfiguration(receivePayloadCapacity: 2049)
        }
    }

    @Test("the public configuration exposes only the MVP fields")
    func configurationHasNoGeneralEscapeHatch() throws(ZenohBindingConfigurationError) {
        let configuration = try ZenohBindingConfiguration()
        let mirror = Mirror(reflecting: configuration)
        let labels = Set(mirror.children.compactMap(\.label))

        #expect(labels == [
            "mode",
            "connectEndpoint",
            "maximumProfileKeyBytes",
            "maximumExternalRoutes",
            "receiveQueueCapacity",
            "receiveKeyCapacity",
            "receivePayloadCapacity",
        ])
    }
}
