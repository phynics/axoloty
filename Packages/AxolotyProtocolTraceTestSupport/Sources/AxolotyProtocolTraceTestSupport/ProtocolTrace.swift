// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Axoloty
import AxolotyProtocol

/// The thirteen Coaty Core wire families carried by the trace contract.
enum TraceEventFamily: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case advertise = "ADV"
    case deadvertise = "DAD"
    case channel = "CHN"
    case associate = "ASC"
    case ioValue = "IOV"
    case discover = "DSC"
    case resolve = "RSV"
    case query = "QRY"
    case retrieve = "RTV"
    case update = "UPD"
    case complete = "CPL"
    case call = "CLL"
    case `return` = "RTN"
}

enum TraceDirection: String, Codable, Equatable, Sendable { case inbound, outbound }
enum TraceRouteClassification: String, Codable, Equatable, Sendable { case coaty, external }
enum TraceLocalOperation: String, Codable, Equatable, Sendable { case processInbound, publishOutbound }
enum TraceRejectionCode: String, Codable, Equatable, Sendable {
    case malformed, payloadTooLarge, unsupported, duplicate, saturated, deadlineExpired, correlationMismatch, externalRouteMismatch
}

typealias NormalizedProtocolState = TraceState

struct TraceState: Codable, Equatable, Sendable {
    let activeObjectIDs: [String]
    let pendingCorrelationIDs: [String]
    let associationIDs: [String]
    let generation: Int

    init(activeObjectIDs: [String] = [], pendingCorrelationIDs: [String] = [], associationIDs: [String] = [], generation: Int = 0) {
        self.activeObjectIDs = activeObjectIDs.sorted()
        self.pendingCorrelationIDs = pendingCorrelationIDs.sorted()
        self.associationIDs = associationIDs.sorted()
        self.generation = generation
    }
}

struct TraceCapabilities: Codable, Equatable, Sendable {
    let supportedFamilies: [TraceEventFamily]
    init(supportedFamilies: [TraceEventFamily] = TraceEventFamily.allCases) {
        self.supportedFamilies = supportedFamilies.sorted { $0.rawValue < $1.rawValue }
    }
}

struct TraceLimits: Codable, Equatable, Sendable {
    let maximumPayloadBytes: Int
    let maximumObjects: Int
    let maximumPendingCorrelations: Int
    static let `default` = TraceLimits(maximumPayloadBytes: 2_048, maximumObjects: 4, maximumPendingCorrelations: 4)
}

struct TraceInput: Codable, Equatable, Sendable {
    let family: TraceEventFamily
    let direction: TraceDirection
    let fixtureID: String
    let fixturePayload: String
    let payloadBytes: Int
    let objectID: String?
    let correlationID: String?
    let associatingRoute: String?
    let routeClassification: TraceRouteClassification?
    let isExternalRoute: Bool?
    let duplicate: Bool
    let malformed: Bool
    let deadlineExpired: Bool

    init(
        family: TraceEventFamily,
        direction: TraceDirection,
        fixtureID: String,
        fixturePayload: String,
        objectID: String? = nil,
        correlationID: String? = nil,
        associatingRoute: String? = nil,
        routeClassification: TraceRouteClassification? = nil,
        isExternalRoute: Bool? = nil,
        duplicate: Bool = false,
        malformed: Bool? = nil,
        deadlineExpired: Bool = false
    ) {
        self.family = family
        self.direction = direction
        self.fixtureID = fixtureID
        self.fixturePayload = fixturePayload
        self.payloadBytes = fixturePayload.utf8.count
        self.objectID = objectID
        self.correlationID = correlationID
        self.associatingRoute = associatingRoute
        self.routeClassification = routeClassification
        self.isExternalRoute = isExternalRoute
        self.duplicate = duplicate
        self.malformed = malformed ?? ((try? JSONSerialization.jsonObject(
            with: Data(fixturePayload.utf8),
            options: [.fragmentsAllowed]
        )) == nil)
        self.deadlineExpired = deadlineExpired
    }
}

struct TraceAction: Codable, Equatable, Sendable {
    let kind: String
    let family: TraceEventFamily
    let correlationID: String?
    let route: String?
    let payload: [UInt8]?

    init(kind: String, family: TraceEventFamily, correlationID: String? = nil, route: String? = nil, payload: [UInt8]? = nil) {
        self.kind = kind
        self.family = family
        self.correlationID = correlationID
        self.route = route
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case kind, family, correlationID, route, payload }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        family = try container.decode(TraceEventFamily.self, forKey: .family)
        correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID)
        route = try container.decodeIfPresent(String.self, forKey: .route)
        payload = try container.decodeIfPresent([UInt8].self, forKey: .payload)
    }
}

struct TraceRejection: Codable, Equatable, Sendable {
    let code: TraceRejectionCode
    let reason: String
}

struct TraceObservation: Codable, Equatable, Sendable {
    let actions: [TraceAction]
    let rejection: TraceRejection?
    let nextState: TraceState
}

struct TraceStep: Codable, Equatable, Sendable {
    let sequence: Int
    let timeMilliseconds: UInt64
    let priorState: TraceState
    let capabilities: TraceCapabilities
    let limits: TraceLimits
    let input: TraceInput
    let localOperation: TraceLocalOperation
    let expected: TraceObservation
}

struct ProtocolTrace: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let id: String
    let description: String
    let initialState: TraceState
    let setup: [TraceStep]
    let steps: [TraceStep]

    init(id: String, description: String, initialState: TraceState, setup: [TraceStep] = [], steps: [TraceStep]) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.description = description
        self.initialState = initialState
        self.setup = setup
        self.steps = steps
    }
}

/// The executable scenario spelling used by the G6 evidence contract.
typealias ProtocolTraceScenario = ProtocolTrace

struct TraceRun: Codable, Equatable, Sendable {
    let traceID: String
    let observations: [TraceObservation]
}

enum TraceReplayError: Error, Equatable, Sendable {
    case schemaVersion(Int)
    case stateMismatch(traceID: String, sequence: Int)
    case expectedMismatch(traceID: String, sequence: Int)
    case staticCapacityExceeded(traceID: String, sequence: Int)
    case missingRuntimeReceipt(traceID: String, sequence: Int)
}

protocol TraceReplayAdapter: Sendable {
    func replay(_ trace: ProtocolTrace) async throws -> TraceRun
}

/// A runtime transport with a deterministic inbound-frame injection seam.
protocol RuntimeTraceCarrier: AxolotyRuntimeTransport {
    func inject(_ frame: RuntimeInboundFrame) async throws
    func setOutboundEffectsEnabled(_ enabled: Bool)
}

/// The bounded, executable trace-driver contract used by both runtime profiles.
protocol RuntimeTraceDriver: ~Copyable {
    mutating func start() async throws
    mutating func apply(_ step: TraceStep) async throws -> TraceObservation
    mutating func snapshot() async -> TraceState
    mutating func stop() async
}
