// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum ZenohFacadeContract {
    static func load() throws(FixtureError) -> Document {
        guard let url = Bundle.module.url(forResource: "axoloty-zenoh-facade-v1", withExtension: "json") else {
            throw .resourceMissing
        }
        do {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw .invalidDocument
        }
    }

    struct Document: Decodable {
        let contractVersion: String
        let vectors: Vectors
    }

    struct Vectors: Decodable {
        let roundTrip: Frame
        let multipleSubscribers: Frame
        let queueOverflow: QueueOverflow
        let keyOverflow: Overflow
        let payloadOverflow: Overflow
        let sessionFailure: SessionFailure
    }

    struct Frame: Decodable {
        let key: String
        let payload: [UInt8]
    }

    struct QueueOverflow: Decodable {
        let key: String
        let acceptedPayloads: [[UInt8]]
        let overflowPayload: [UInt8]
        let expectedDroppedFrameCount: UInt32
    }

    struct Overflow: Decodable {
        let keyLength: Int
        let payloadLength: Int
        let fillByte: UInt8
    }

    struct SessionFailure: Decodable {
        let endpoint: String
    }

    enum FixtureError: Error {
        case resourceMissing
        case invalidDocument
    }
}
