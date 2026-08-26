// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A self-test ownership entry shared with the Node validator.
public struct AxolotySelfTestContractEntry: Codable, Equatable, Sendable {
    /// Repository-relative self-test path.
    public let path: String
    /// Owning Make target.
    public let makeTarget: String
    /// Owning tier.
    public let tier: String

    /// Creates a self-test contract entry.
    public init(path: String, makeTarget: String, tier: String) {
        self.path = path
        self.makeTarget = makeTarget
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
