// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A validated full Git commit identifier.
public struct AxolotyGitCommitSHA: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The canonical lowercase hexadecimal value.
    public let value: String

    /// Creates a commit identifier.
    ///
    /// - Parameter value: A full 40-character hexadecimal Git object id.
    /// - Throws: ``AxolotyReleaseEvidenceError/invalidSubject`` when the value is not a full SHA.
    public init(_ value: String) throws {
        let normalized = value.lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw AxolotyReleaseEvidenceError.invalidSubject("commit must be a full 40-character hexadecimal SHA")
        }
        self.value = normalized
    }

    /// The canonical string representation.
    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A validated full Git tree identifier.
public struct AxolotyGitTreeSHA: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The canonical lowercase hexadecimal value.
    public let value: String

    /// Creates a tree identifier.
    ///
    /// - Parameter value: A full 40-character hexadecimal Git tree object id.
    /// - Throws: ``AxolotyReleaseEvidenceError/invalidSubject`` when the value is not a full SHA.
    public init(_ value: String) throws {
        let normalized = value.lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw AxolotyReleaseEvidenceError.invalidSubject("tree must be a full 40-character hexadecimal SHA")
        }
        self.value = normalized
    }

    /// The canonical string representation.
    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The repository identity to which release evidence belongs.
public struct AxolotyRepositoryIdentity: Codable, Equatable, Hashable, Sendable {
    /// The canonical repository URL or owner/name identifier.
    public let value: String

    /// Creates a repository identity.
    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("\n"),
              !normalized.contains("\r") else {
            throw AxolotyReleaseEvidenceError.invalidSubject("repository identity must be non-empty")
        }
        self.value = normalized
    }
}

/// A release version bound to evidence.
public struct AxolotySemanticVersion: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The normalized semantic version string.
    public let value: String

    /// Creates a semantic version.
    ///
    /// This accepts prerelease and build metadata while requiring a numeric
    /// major, minor, and patch component.
    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = normalized.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              !normalized.contains(" "),
              !normalized.isEmpty else {
            throw AxolotyReleaseEvidenceError.invalidSubject("version must be semantic major.minor.patch")
        }
        self.value = normalized
    }

    /// The canonical string representation.
    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The exact source subject certified by a release evidence bundle.
public struct AxolotyReleaseSubject: Codable, Equatable, Sendable {
    /// Repository identity.
    public let repository: AxolotyRepositoryIdentity
    /// Full commit SHA.
    public let commit: AxolotyGitCommitSHA
    /// Full tree SHA.
    public let tree: AxolotyGitTreeSHA
    /// Semantic version.
    public let version: AxolotySemanticVersion
    /// Whether the producer observed a clean checkout.
    public let clean: Bool

    /// Creates a release subject.
    public init(
        repository: AxolotyRepositoryIdentity,
        commit: AxolotyGitCommitSHA,
        tree: AxolotyGitTreeSHA,
        version: AxolotySemanticVersion,
        clean: Bool
    ) {
        self.repository = repository
        self.commit = commit
        self.tree = tree
        self.version = version
        self.clean = clean
    }
}

/// A stable release gate identifier.
public struct AxolotyReleaseGateID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The raw gate identifier.
    public let rawValue: String

    /// Creates a gate identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a gate identifier from a string literal.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The deterministic G6 gate.
    public static let g6NonDivergence: Self = "g6-non-divergence"
}

/// Whether evidence was generated during the current invocation or imported.
public enum AxolotyEvidenceDisposition: String, Codable, Equatable, Sendable {
    /// Evidence was generated by the current checkpoint invocation.
    case currentRun = "current-run"
    /// Evidence was imported from an external producer.
    case imported
}

/// Provenance for evidence imported from CI, hardware, or another trusted producer.
public struct AxolotyEvidenceProvenance: Codable, Equatable, Sendable {
    /// The external system that produced the evidence.
    public let issuer: String
    /// Workflow, job, run, or device collection identifier.
    public let runID: String
    /// The source commit recorded by the external producer.
    public let commit: AxolotyGitCommitSHA

    /// Creates external provenance.
    public init(issuer: String, runID: String, commit: AxolotyGitCommitSHA) {
        self.issuer = issuer
        self.runID = runID
        self.commit = commit
    }
}

/// Identity and execution context for an evidence producer.
public struct AxolotyEvidenceProducerIdentity: Codable, Equatable, Sendable {
    /// Stable producer name.
    public let id: String
    /// Producer implementation version.
    public let version: String
    /// Local or imported evidence.
    public let disposition: AxolotyEvidenceDisposition
    /// External provenance when evidence is imported.
    public let provenance: AxolotyEvidenceProvenance?

    /// Creates a producer identity.
    public init(
        id: String,
        version: String,
        disposition: AxolotyEvidenceDisposition,
        provenance: AxolotyEvidenceProvenance? = nil
    ) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AxolotyReleaseEvidenceError.invalidProducer("producer id and version must be non-empty")
        }
        if disposition == .imported, provenance == nil {
            throw AxolotyReleaseEvidenceError.missingProvenance
        }
        if disposition == .currentRun, provenance != nil {
            throw AxolotyReleaseEvidenceError.invalidProducer("current-run evidence cannot carry external provenance")
        }
        self.id = id
        self.version = version
        self.disposition = disposition
        self.provenance = provenance
    }
}

/// A digest and declaration for one evidence artifact.
public struct AxolotyEvidenceArtifact: Codable, Equatable, Sendable {
    /// A semantic role such as `capture` or `log`.
    public let role: String
    /// A bundle-relative path.
    public let relativePath: String
    /// Lowercase hexadecimal SHA-256 digest.
    public let sha256: String
    /// Artifact size in bytes.
    public let byteCount: Int
    /// MIME type or stable artifact media type.
    public let mediaType: String

    /// Creates an artifact declaration.
    public init(role: String, relativePath: String, sha256: String, byteCount: Int, mediaType: String) throws {
        guard !role.isEmpty, !mediaType.isEmpty, byteCount >= 0,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }) else {
            throw AxolotyReleaseEvidenceError.invalidArtifact(relativePath)
        }
        self.role = role
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.mediaType = mediaType
    }
}

/// The result declared by an evidence producer.
public enum AxolotyEvidenceResult: String, Codable, Equatable, Sendable {
    /// Evidence passed its producer-local checks.
    case passed
    /// Evidence was collected but failed its producer-local checks.
    case failed
}

/// A typed, versioned evidence document.
public struct AxolotyEvidenceEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    /// Current universal envelope schema.
    public static let currentSchemaVersion = 1

    /// Universal envelope schema version.
    public let envelopeSchema: Int
    /// Gate covered by this evidence.
    public let gate: AxolotyReleaseGateID
    /// Gate-specific payload schema version.
    public let gateSchema: Int
    /// Exact release subject.
    public let subject: AxolotyReleaseSubject
    /// Producer identity.
    public let producer: AxolotyEvidenceProducerIdentity
    /// Referenced raw artifacts.
    public let artifacts: [AxolotyEvidenceArtifact]
    /// Producer-local outcome.
    public let result: AxolotyEvidenceResult
    /// Gate-specific typed evidence.
    public let payload: Payload

    /// Creates an evidence envelope.
    public init(
        envelopeSchema: Int = Self.currentSchemaVersion,
        gate: AxolotyReleaseGateID,
        gateSchema: Int,
        subject: AxolotyReleaseSubject,
        producer: AxolotyEvidenceProducerIdentity,
        artifacts: [AxolotyEvidenceArtifact],
        result: AxolotyEvidenceResult,
        payload: Payload
    ) {
        self.envelopeSchema = envelopeSchema
        self.gate = gate
        self.gateSchema = gateSchema
        self.subject = subject
        self.producer = producer
        self.artifacts = artifacts
        self.result = result
        self.payload = payload
    }
}

/// A JSON value used when the checkpoint only needs to validate universal envelope fields.
public enum AxolotyJSONValue: Codable, Equatable, Sendable {
    /// Null.
    case null
    /// Boolean.
    case boolean(Bool)
    /// Number represented without loss of its JSON spelling.
    case number(String)
    /// String.
    case string(String)
    /// Array.
    case array([Self])
    /// Object.
    case object([String: Self])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int64.self) { self = .number(String(value)); return }
        if let value = try? container.decode(Double.self) { self = .number(String(value)); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([Self].self) { self = .array(value); return }
        self = .object(try container.decode([String: Self].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A release-evidence validation failure.
public enum AxolotyReleaseEvidenceError: Error, Equatable, Sendable, LocalizedError {
    /// The release subject is malformed or does not match the expected subject.
    case invalidSubject(String)
    /// The producer identity is malformed.
    case invalidProducer(String)
    /// Imported evidence has no provenance.
    case missingProvenance
    /// The artifact declaration is invalid.
    case invalidArtifact(String)
    /// The evidence bundle could not be read.
    case unreadable(String)
    /// The envelope could not be decoded.
    case malformedEnvelope(String)
    /// An envelope or gate payload schema is unsupported.
    case unsupportedSchema(String)
    /// A referenced artifact is absent or differs from its declaration.
    case artifactMismatch(String)
    /// Evidence belongs to another gate.
    case gateMismatch(expected: String, actual: String)
    /// Evidence belongs to another release subject.
    case subjectMismatch(String)
    /// The producer returned a failed result.
    case failedEvidence

    /// A command-safe diagnostic.
    public var errorDescription: String? {
        switch self {
        case .invalidSubject(let reason): return "invalid evidence subject: \(reason)"
        case .invalidProducer(let reason): return "invalid evidence producer: \(reason)"
        case .missingProvenance: return "imported evidence requires provenance"
        case .invalidArtifact(let path): return "invalid evidence artifact: \(path)"
        case .unreadable(let path): return "unable to read evidence bundle: \(path)"
        case .malformedEnvelope(let reason): return "malformed evidence envelope: \(reason)"
        case .unsupportedSchema(let schema): return "unsupported evidence schema: \(schema)"
        case .artifactMismatch(let path): return "evidence artifact mismatch: \(path)"
        case .gateMismatch(let expected, let actual): return "evidence gate mismatch: expected \(expected), got \(actual)"
        case .subjectMismatch(let reason): return "evidence subject mismatch: \(reason)"
        case .failedEvidence: return "evidence producer reported failure"
        }
    }
}

/// The release subject expected by an evidence validation invocation.
public struct AxolotyEvidenceValidationContext: Sendable {
    /// The exact subject expected by the checkpoint.
    public let expectedSubject: AxolotyReleaseSubject
    /// The bundle root containing `evidence.json` and its artifacts.
    public let bundleRoot: URL
    /// Creates a validation context.
    public init(expectedSubject: AxolotyReleaseSubject, bundleRoot: URL) {
        self.expectedSubject = expectedSubject
        self.bundleRoot = bundleRoot.standardizedFileURL
    }
}

/// A validated gate result consumed by the checkpoint aggregator.
public struct AxolotyValidatedGateEvidence: Equatable, Sendable {
    /// Gate identity.
    public let gate: AxolotyReleaseGateID
    /// Exact validated subject.
    public let subject: AxolotyReleaseSubject
    /// Digest of the complete evidence document.
    public let bundleDigest: String
    /// Producer identity.
    public let producer: AxolotyEvidenceProducerIdentity

    /// Creates a validated result.
    public init(
        gate: AxolotyReleaseGateID,
        subject: AxolotyReleaseSubject,
        bundleDigest: String,
        producer: AxolotyEvidenceProducerIdentity
    ) {
        self.gate = gate
        self.subject = subject
        self.bundleDigest = bundleDigest
        self.producer = producer
    }
}

/// A SHA-256 implementation used for evidence integrity without a platform crypto dependency.
public struct AxolotySHA256: Sendable {
    /// Creates a SHA-256 hasher.
    public init() {}

    /// Hashes data and returns a lowercase hexadecimal digest.
    public func hash(_ data: Data) -> String {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: [
            UInt8((bitLength >> 56) & 0xff), UInt8((bitLength >> 48) & 0xff),
            UInt8((bitLength >> 40) & 0xff), UInt8((bitLength >> 32) & 0xff),
            UInt8((bitLength >> 24) & 0xff), UInt8((bitLength >> 16) & 0xff),
            UInt8((bitLength >> 8) & 0xff), UInt8(bitLength & 0xff),
        ])
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let constants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
            0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
            0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
            0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
            0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
            0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
            0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
            0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
            (value >> amount) | (value << (32 - amount))
        }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var schedule = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = UInt32(bytes[base]) << 24
                    | UInt32(bytes[base + 1]) << 16
                    | UInt32(bytes[base + 2]) << 8
                    | UInt32(bytes[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7)
                    ^ rotateRight(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17)
                    ^ rotateRight(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ schedule[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }
}

/// Loads and validates the universal portion of one evidence bundle.
public struct AxolotyEvidenceBundleLoader: Sendable {
    /// Creates a bundle loader.
    public init() {}

    /// Validates `evidence.json` and every declared artifact in a bundle.
    ///
    /// - Parameters:
    ///   - bundle: Directory containing `evidence.json`.
    ///   - expectedGate: Gate required by the caller.
    ///   - context: Exact subject and bundle root expected by the caller.
    /// - Returns: A validated gate result suitable for aggregation.
    public func validate(
        bundle: URL,
        expectedGate: AxolotyReleaseGateID,
        context: AxolotyEvidenceValidationContext
    ) throws -> AxolotyValidatedGateEvidence {
        let root = bundle.standardizedFileURL
        guard root == context.bundleRoot else {
            throw AxolotyReleaseEvidenceError.subjectMismatch("bundle root differs from validation context")
        }
        let evidenceURL = root.appendingPathComponent("evidence.json")
        guard let data = try? Data(contentsOf: evidenceURL) else {
            throw AxolotyReleaseEvidenceError.unreadable(evidenceURL.path)
        }
        let envelope: AxolotyEvidenceEnvelope<AxolotyJSONValue>
        do {
            envelope = try JSONDecoder().decode(
                AxolotyEvidenceEnvelope<AxolotyJSONValue>.self,
                from: data
            )
        } catch {
            throw AxolotyReleaseEvidenceError.malformedEnvelope(error.localizedDescription)
        }
        guard envelope.envelopeSchema == AxolotyEvidenceEnvelope<AxolotyJSONValue>.currentSchemaVersion else {
            throw AxolotyReleaseEvidenceError.unsupportedSchema("envelope=\(envelope.envelopeSchema)")
        }
        guard envelope.gate == expectedGate else {
            throw AxolotyReleaseEvidenceError.gateMismatch(
                expected: expectedGate.rawValue,
                actual: envelope.gate.rawValue
            )
        }
        guard envelope.subject == context.expectedSubject else {
            throw AxolotyReleaseEvidenceError.subjectMismatch("repository, commit, tree, version, or clean state differs")
        }
        guard envelope.subject.clean else {
            throw AxolotyReleaseEvidenceError.invalidSubject("release evidence must come from a clean checkout")
        }
        guard envelope.result == .passed else {
            throw AxolotyReleaseEvidenceError.failedEvidence
        }
        if envelope.producer.disposition == .imported, envelope.producer.provenance == nil {
            throw AxolotyReleaseEvidenceError.missingProvenance
        }
        var paths = Set<String>()
        for artifact in envelope.artifacts {
            guard paths.insert(artifact.relativePath).inserted else {
                throw AxolotyReleaseEvidenceError.artifactMismatch(artifact.relativePath)
            }
            let artifactURL = root.appendingPathComponent(artifact.relativePath).standardizedFileURL
            guard artifactURL.path.hasPrefix(root.path + "/") else {
                throw AxolotyReleaseEvidenceError.invalidArtifact(artifact.relativePath)
            }
            guard let artifactData = try? Data(contentsOf: artifactURL),
                  artifactData.count == artifact.byteCount,
                  AxolotySHA256().hash(artifactData) == artifact.sha256 else {
                throw AxolotyReleaseEvidenceError.artifactMismatch(artifact.relativePath)
            }
        }
        let declared = Set(envelope.artifacts.map(\.relativePath))
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for file in files where file != "evidence.json" {
            let fileURL = root.appendingPathComponent(file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let isDirectory = (attributes?[.type] as? FileAttributeType) == .typeDirectory
            if !isDirectory && !declared.contains(file) {
                throw AxolotyReleaseEvidenceError.artifactMismatch(file)
            }
        }
        let digest = AxolotySHA256().hash(data)
        return AxolotyValidatedGateEvidence(
            gate: envelope.gate,
            subject: envelope.subject,
            bundleDigest: digest,
            producer: envelope.producer
        )
    }
}
