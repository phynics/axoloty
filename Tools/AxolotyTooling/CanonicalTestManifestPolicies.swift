// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A self-test ownership entry shared with the Node validator.
public struct AxolotySelfTestContractEntry: Codable, Equatable, Sendable {
    /// Repository-relative self-test path.
    public let path: String
    /// Owning category. A self-test is owned by the category whose nodes run
    /// it, which is a manifest fact and survives changes to the Make entry
    /// points.
    public let tier: String

    /// Creates a self-test contract entry.
    public init(path: String, tier: String) {
        self.path = path
        self.tier = tier
    }
}

/// Shared artifact names required by the test contract.
public struct AxolotyArtifactContract: Codable, Equatable, Sendable {
    /// Artifacts required after a failure.
    public let requiredOnFailure: [String]
    /// Broker scenario artifacts.
    public let brokerScenarios: [String]
    /// Interoperability scenario artifacts.
    public let interopScenarios: [String]
    /// Generated-input artifacts.
    public let generatedScenarios: [String]

    /// Creates an artifact contract.
    public init(
        requiredOnFailure: [String],
        brokerScenarios: [String],
        interopScenarios: [String],
        generatedScenarios: [String]
    ) {
        self.requiredOnFailure = requiredOnFailure
        self.brokerScenarios = brokerScenarios
        self.interopScenarios = interopScenarios
        self.generatedScenarios = generatedScenarios
    }
}

/// Container environment allowlists for axoloty-tool release commands,
/// keyed by tool command identifier. The make release targets consult the
/// manifest through Tests/Support/tool-container-env.sh; the tier
/// validator enforces the section's shape. Decodes and encodes as the
/// keyed dictionary itself, not as a wrapper object.
public struct AxolotyToolContainerEnv: Codable, Equatable, Sendable {
    /// Allowlisted container environment variable names per tool command.
    public let allowlists: [String: [String]]

    /// Creates a container environment contract.
    public init(allowlists: [String: [String]] = [:]) {
        self.allowlists = allowlists
    }

    /// Creates the contract from the manifest's keyed dictionary.
    public init(from decoder: Decoder) throws {
        allowlists = try [String: [String]](from: decoder)
    }

    /// Encodes the contract as the keyed dictionary.
    public func encode(to encoder: Encoder) throws {
        try allowlists.encode(to: encoder)
    }

    /// The allowlist for a tool command identifier, if declared.
    public func allowlist(for commandIdentifier: String) -> [String]? {
        allowlists[commandIdentifier]
    }
}

/// Shared retry and quarantine policy.
public struct AxolotyFlakePolicy: Codable, Equatable, Sendable {
    /// Automatic retries, which must remain zero.
    public let automaticRetries: Int
    /// Visible diagnostic reruns permitted by the contract.
    public let diagnosticReruns: Int
    /// Required quarantine evidence fields.
    public let quarantineRequires: [String]

    /// Creates a flake policy.
    public init(automaticRetries: Int, diagnosticReruns: Int, quarantineRequires: [String]) {
        self.automaticRetries = automaticRetries
        self.diagnosticReruns = diagnosticReruns
        self.quarantineRequires = quarantineRequires
    }
}
