// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The lifecycle state of a check node.
public enum AxolotyCheckStatus: String, Codable, Equatable, Sendable {
    /// The node has been selected but not run.
    case planned
    /// The node completed successfully.
    case passed
    /// The node ran and failed.
    case failed
    /// The node was not run because a prerequisite failed or was skipped.
    case skipped
}

/// A command that a check executor may run later.
public struct AxolotyCommandPlan: Codable, Equatable, Sendable {
    /// Where a Linux host-delivered CLI executes the command.
    public enum ExecutionContext: String, Codable, Equatable, Sendable {
        /// Run in the pinned project container on Linux, or natively on macOS.
        case project
        /// Run directly beside the host-delivered CLI.
        case host
    }

    /// The executable name.
    public let executable: String
    /// Arguments passed to the executable.
    public let arguments: [String]
    /// Environment values added for the command.
    public let environment: [String: String]
    /// The command execution boundary.
    public let executionContext: ExecutionContext

    /// Creates a command plan.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        executionContext: ExecutionContext = .project
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.executionContext = executionContext
    }
}

/// The captured result of a command execution.
public struct AxolotyCheckCommandResult: Codable, Equatable, Sendable {
    /// The process exit status.
    public let exitCode: Int32
    /// Standard output captured from the process.
    public let standardOutput: String
    /// Standard error captured from the process.
    public let standardError: String

    /// Creates a command result.
    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// A named, dependency-aware check in a check plan.
public struct AxolotyCheckNode: Codable, Equatable, Sendable {
    /// The stable node identifier.
    public let name: String
    /// Names of prerequisite nodes.
    public let dependencies: [String]
    /// The command associated with this node.
    public let command: AxolotyCommandPlan
    /// The node's current status.
    public let status: AxolotyCheckStatus

    /// Creates a check node.
    public init(
        name: String,
        dependencies: [String] = [],
        command: AxolotyCommandPlan,
        status: AxolotyCheckStatus = .planned
    ) {
        self.name = name
        self.dependencies = dependencies
        self.command = command
        self.status = status
    }
}

/// The result associated with a planned check node.
public struct AxolotyCheckResult: Codable, Equatable, Sendable {
    /// The node identifier.
    public let name: String
    /// The final node status.
    public let status: AxolotyCheckStatus
    /// The command result, when execution occurred.
    public let command: AxolotyCheckCommandResult?

    /// Creates a check result.
    public init(name: String, status: AxolotyCheckStatus, command: AxolotyCheckCommandResult? = nil) {
        self.name = name
        self.status = status
        self.command = command
    }
}

/// A deterministic collection of check nodes in execution order.
public struct AxolotyCheckPlan: Codable, Equatable, Sendable {
    /// The plan schema version.
    public let schemaVersion: Int
    /// Nodes ordered so every prerequisite precedes its dependants.
    public let nodes: [AxolotyCheckNode]

    /// Creates a check plan.
    public init(schemaVersion: Int = 1, nodes: [AxolotyCheckNode]) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
    }

    /// The canonical broker-free project checks owned by the CLI.
    /// The platform used when selecting platform-specific checks.
    public enum Platform: String, Codable, Equatable, Sendable {
        /// Apple macOS.
        case macOS
        /// Linux.
        case linux
    }

    /// The host platform selected at compile time.
    public static let currentPlatform: Platform = {
        #if os(Linux)
        .linux
        #else
        .macOS
        #endif
    }()

    /// The initial offline checks for the current host platform.
    public static let initialOffline = initialOffline(for: currentPlatform)

    /// Creates initial offline checks for a selected host platform.
    public static func initialOffline(for platform: Platform) -> AxolotyCheckPlan {
        var nodes: [AxolotyCheckNode] = [
        AxolotyCheckNode(name: "resolve", command: AxolotyCommandPlan(executable: "swift", arguments: ["package", "resolve", "--cache-path", ".swiftpm-cache"])),
        AxolotyCheckNode(name: "build", dependencies: ["resolve"], command: AxolotyCommandPlan(executable: "swift", arguments: ["build", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution"])),
        AxolotyCheckNode(name: "lint", command: AxolotyCommandPlan(executable: "swiftlint", arguments: ["lint", "--config", ".swiftlint.yml"])),
        AxolotyCheckNode(name: "test-tooling", dependencies: ["build"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--filter", "AxolotyToolingTests"])),
        AxolotyCheckNode(name: "test-unit", dependencies: ["test-tooling"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--skip-build", "--filter", "ObjectMatcherTests|CoatyUUIDTests"])),
        AxolotyCheckNode(name: "test-module", dependencies: ["test-tooling"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--skip-build", "--filter", "CommunicationTopicTests|PayloadCoderTests|ObjectTypeRegistryTests|ConfigurationBuilderTests"])),
        AxolotyCheckNode(name: "test-fuzz", dependencies: ["test-tooling"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--skip-build", "--filter", "DeterministicFuzzTests"], environment: ["AXOLOTY_FUZZ_ITERATIONS": "250", "AXOLOTY_FUZZ_SEED": "0x41584f4c4f5459"])),
        AxolotyCheckNode(name: "test-wire", dependencies: ["test-tooling"], command: AxolotyCommandPlan(executable: "swift", arguments: ["test", "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution", "--skip-build", "--filter", "WireFixtureTests|LegacyCaptureFixtureTests|CoatyJs.*CaptureTests|LifecycleCompatibilityScenarioTests|AxolotyIoAssociateTests|AxolotyIoNegativeTests"])),
        AxolotyCheckNode(name: "no-anycodable", command: AxolotyCommandPlan(executable: "Tests/Support/check-no-anycodable.sh")),
        AxolotyCheckNode(name: "no-foundation-wire", command: AxolotyCommandPlan(executable: "Tests/Support/check-no-foundation-types.sh")),
        AxolotyCheckNode(name: "wire-dependencies", command: AxolotyCommandPlan(executable: "sh", arguments: ["Tests/Support/check-axoloty-wire-dependencies.sh", "Packages/AxolotyWire"])),
        AxolotyCheckNode(name: "wire-independent-resolution", command: AxolotyCommandPlan(executable: "Tests/Support/check-axoloty-wire-independent-resolution.sh")),
        ]
        let supportSelfTests = [
            ("support-wire-dependencies", "Tests/Support/test-check-axoloty-wire-dependencies.sh"),
            ("support-wire-resolution", "Tests/Support/test-check-axoloty-wire-independent-resolution.sh"),
            ("support-wire-isolation", "Tests/Support/test-check-axoloty-wire-test-isolation.sh"),
            ("support-benchmark-corpus", "Tests/Support/test-check-benchmark-corpus.sh"),
            ("support-benchmark-size", "Tests/Support/test-check-benchmark-size.sh"),
            ("support-benchmark-wire", "Tests/Support/test-check-benchmark-wire.sh"),
            ("support-benchmark-bounds", "Tests/Support/test-check-benchmark-wire-bounds.sh"),
            ("support-budget-manifest", "Tests/Support/test-check-budget-manifest.sh"),
        ]
        nodes += supportSelfTests.map { name, executable in
            AxolotyCheckNode(name: name, command: AxolotyCommandPlan(executable: executable))
        }
        nodes.append(AxolotyCheckNode(
            name: "support-node-tests",
            command: AxolotyCommandPlan(executable: "node", arguments: [
                "--test",
                "Tests/Support/coverage-tools.test.mjs",
                "Tests/Support/fuzz-summary.test.mjs",
                "Tests/Support/make-tooling-wrappers.test.mjs",
                "Tests/Support/patch-swift-got.test.mjs",
                "Tests/Support/release-snapshots.test.mjs",
                "Tests/Support/serial-tools.test.mjs",
                "Tests/Support/validate-test-tiers.test.mjs",
                "Tests/Support/work-plan-issue-form.test.mjs",
            ])
        ))
        nodes.append(AxolotyCheckNode(
            name: "support-tier-contract",
            dependencies: ["support-node-tests"],
            command: AxolotyCommandPlan(
                executable: "node",
                arguments: ["Tests/Support/validate-test-tiers.mjs", "Tests/Support/test-tiers.json"]
            )
        ))
        if platform == .linux {
            nodes += [
                AxolotyCheckNode(name: "support-container", command: AxolotyCommandPlan(executable: "Tests/Support/test-run-container.sh")),
                AxolotyCheckNode(name: "support-fuzz-runner", command: AxolotyCommandPlan(executable: "Tests/Fuzzing/test-run-fuzz.sh")),
                AxolotyCheckNode(name: "support-embedded-compile", command: AxolotyCommandPlan(executable: "Tests/Support/test-check-embedded-swift.sh")),
                AxolotyCheckNode(name: "support-embedded-smoke", command: AxolotyCommandPlan(executable: "Tests/Support/test-embedded-swift-smoke.sh")),
                AxolotyCheckNode(name: "embedded-build", dependencies: ["build"], command: AxolotyCommandPlan(executable: "Tests/Support/build-embedded-swift.sh")),
                AxolotyCheckNode(name: "embedded-linker", dependencies: ["embedded-build"], command: AxolotyCommandPlan(executable: "Tests/Support/check-embedded-swift-linker.sh")),
            ]
        }
        return AxolotyCheckPlan(nodes: nodes)
    }

    /// Creates the release snapshot generation and offline verification plan.
    public static func releaseSnapshots(
        source: String = "Tests/WireCompatibility/Fixtures",
        destination: String = ".testing/release-snapshots",
        environment: [String: String] = [:]
    ) -> AxolotyCheckPlan {
        AxolotyCheckPlan(nodes: [
            AxolotyCheckNode(
                name: "release-snapshots-generate",
                command: AxolotyCommandPlan(
                    executable: "node",
                    arguments: ["Tests/Support/release-snapshots.mjs", "generate", source, destination],
                    environment: environment
                )
            ),
            AxolotyCheckNode(
                name: "release-snapshots-verify",
                dependencies: ["release-snapshots-generate"],
                command: AxolotyCommandPlan(
                    executable: "node",
                    arguments: ["Tests/Support/release-snapshots.mjs", "verify", destination]
                )
            ),
        ])
    }

    /// Creates the explicit host/container plan for live wire capture.
    public static var wireCapture: AxolotyCheckPlan {
        let host: AxolotyCommandPlan.ExecutionContext = .host
        return AxolotyCheckPlan(nodes: [
            AxolotyCheckNode(
                name: "wire-tool-install",
                command: AxolotyCommandPlan(
                    executable: "npm",
                    arguments: ["ci", "--prefix", "Tests/WireCompatibility/tool"]
                )
            ),
            AxolotyCheckNode(
                name: "wire-tool-test",
                dependencies: ["wire-tool-install"],
                command: AxolotyCommandPlan(
                    executable: "npm",
                    arguments: ["test", "--prefix", "Tests/WireCompatibility/tool"]
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-advertise",
                dependencies: ["wire-tool-test"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Live/run-coatyjs-advertise.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-core",
                dependencies: ["wire-capture-advertise"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Live/run-coatyjs-core.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-lifecycle",
                dependencies: ["wire-capture-core"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Lifecycle/Live/run-lifecycle-matrix.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-reverse-advertise",
                dependencies: ["wire-capture-lifecycle"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-reverse-core",
                dependencies: ["wire-capture-reverse-advertise"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Reverse/run-axoloty-core.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-js-to-axoloty",
                dependencies: ["wire-capture-reverse-core"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-io",
                dependencies: ["wire-capture-js-to-axoloty"],
                command: AxolotyCommandPlan(
                    executable: "Tests/WireCompatibility/IO/Live/run-io-associate.sh",
                    executionContext: host
                )
            ),
            AxolotyCheckNode(
                name: "wire-capture-manifest",
                dependencies: ["wire-capture-io"],
                command: AxolotyCommandPlan(
                    executable: "node",
                    arguments: [
                        "Tests/WireCompatibility/tool/dist/index.js", "manifest",
                        ".testing/wire", ".testing/wire/manifest.json",
                    ]
                )
            ),
        ])
    }

}

/// A versioned machine-readable result from an ``axoloty-tool`` check plan.
public struct AxolotyCheckManifest: Codable, Equatable, Sendable {
    /// The result schema version.
    public let schemaVersion: Int
    /// The platform whose plan was executed.
    public let platform: AxolotyCheckPlan.Platform
    /// Results in deterministic plan order.
    public let results: [AxolotyCheckResult]

    /// Creates a check manifest.
    public init(
        schemaVersion: Int = 1,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        results: [AxolotyCheckResult]
    ) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.results = results
    }
}

/// Errors found while expanding a check dependency graph.
public enum AxolotyCheckPlanningError: Error, Equatable, Sendable {
    /// A dependency name is not present in the supplied nodes.
    case missingDependency(node: String, dependency: String)
    /// The graph contains a dependency cycle.
    case cycle([String])
    /// Two nodes use the same stable name.
    case duplicateNode(String)
}

/// Expands check nodes into a stable topological order.
public struct AxolotyCheckPlanner: Sendable {
    /// Creates a planner.
    public init() {}

    /// Plans the requested nodes and all of their prerequisites.
    ///
    /// Duplicate prerequisites are emitted once. Ties are resolved by the
    /// order in which nodes were supplied, making output reproducible.
    public func plan(_ nodes: [AxolotyCheckNode], requested: [String]? = nil) throws -> AxolotyCheckPlan {
        var byName: [String: AxolotyCheckNode] = [:]
        for node in nodes {
            guard byName[node.name] == nil else { throw AxolotyCheckPlanningError.duplicateNode(node.name) }
            byName[node.name] = node
        }
        let roots = requested ?? nodes.map(\.name)
        var included = Set<String>()
        var visiting = Set<String>()
        var stack: [String] = []
        var ordered: [AxolotyCheckNode] = []

        func visit(_ name: String) throws {
            guard let node = byName[name] else {
                let owner = stack.last ?? name
                throw AxolotyCheckPlanningError.missingDependency(node: owner, dependency: name)
            }
            if included.contains(name) { return }
            if visiting.contains(name) {
                throw AxolotyCheckPlanningError.cycle(stack + [name])
            }
            visiting.insert(name)
            stack.append(name)
            for dependency in node.dependencies { try visit(dependency) }
            _ = stack.popLast()
            visiting.remove(name)
            included.insert(name)
            ordered.append(node)
        }

        for root in roots { try visit(root) }
        return AxolotyCheckPlan(nodes: ordered)
    }
}

/// Runs an ``AxolotyCommandPlan`` and captures its externally visible result.
public protocol AxolotyCheckCommandRunning: Sendable {
    /// Executes a command.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: Its captured process result.
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult
}

/// Executes a planned check graph while preserving prerequisite failures.
public struct AxolotyCheckExecutor: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning

    /// Creates an executor with the command runner used for every node.
    ///
    /// - Parameter commandRunner: The boundary that starts child commands.
    public init(commandRunner: any AxolotyCheckCommandRunning) {
        self.commandRunner = commandRunner
    }

    /// Runs a plan in dependency order.
    ///
    /// A node whose prerequisite failed or was skipped is skipped without
    /// invoking the runner. Execution continues after independent failures so
    /// the manifest describes every planned check.
    ///
    /// - Parameter plan: The plan to execute.
    /// - Returns: Results in the plan's deterministic order.
    public func execute(_ plan: AxolotyCheckPlan) -> [AxolotyCheckResult] {
        var statuses: [String: AxolotyCheckStatus] = [:]
        var results: [AxolotyCheckResult] = []

        for node in plan.nodes {
            guard node.dependencies.allSatisfy({ statuses[$0] == .passed }) else {
                statuses[node.name] = .skipped
                results.append(AxolotyCheckResult(name: node.name, status: .skipped))
                continue
            }

            let commandResult = commandRunner.run(node.command)
            let status: AxolotyCheckStatus = commandResult.exitCode == 0 ? .passed : .failed
            statuses[node.name] = status
            results.append(AxolotyCheckResult(name: node.name, status: status, command: commandResult))
        }

        return results
    }
}
