// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The canonical test categories. A category says what a run needs, and that
/// is the only axis: `ci` needs nothing beyond the container, `wire` needs
/// broker infrastructure, `embedded` needs an attached board, and `release`
/// is everything the host can run.
enum CanonicalTier: String, CaseIterable, Sendable {
    case ci
    case wire
    case embedded
    case release
}

enum CanonicalPlanRequest: Sendable {
    case tier(
        name: String,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform,
        requested: [String]? = nil
    )
    case checkpoint(
        hardwareDevice: String?,
        consumerEnvironment: [String: String],
        platform: AxolotyCheckPlan.Platform
    )
    case wireCapture(
        environment: [String: String],
        platform: AxolotyCheckPlan.Platform
    )
}

enum CanonicalCommandRequest: Sendable {
    case node(name: String)
    case testOne(filter: String)
    case testOneOrNode(value: String, platform: AxolotyCheckPlan.Platform)
    case timing(
        scenario: AxolotyTimingScenario,
        mode: AxolotyTimingMode,
        workspace: String,
        filter: String
    )
}

struct AxolotyCanonicalTestPlanResolver: Sendable {
    let manifest: AxolotyCanonicalTestManifest

    init(environment: [String: String]) throws {
        manifest = try Self.loadManifest(environment: environment)
    }

    init(manifest: AxolotyCanonicalTestManifest) {
        self.manifest = manifest
    }

    func resolve(_ request: CanonicalPlanRequest) throws -> AxolotyCheckPlan {
        try validateManifest()
        switch request {
        case .tier(let name, let ci, let platform, let requested):
            return try resolveTier(name, ci: ci, platform: platform, requested: requested)
        case .checkpoint(let hardwareDevice, let consumerEnvironment, let platform):
            let plan = try resolveTier(
                CanonicalTier.release.rawValue,
                ci: false,
                platform: platform
            )
            var environment = consumerEnvironment
            if let hardwareDevice {
                environment["EMBEDDED_DEVICE"] = hardwareDevice
            }
            return rewrite(plan, substitutions: [:], environment: environment)
        case .wireCapture(let environment, let platform):
            let plan = try resolveTier(CanonicalTier.wire.rawValue, ci: false, platform: platform)
            let outputDirectory = environment["WIRE_OUTPUT_DIR"] ?? ".testing/wire"
            var overlay = environment
            overlay["WIRE_OUTPUT_DIR"] = outputDirectory
            if let runID = environment["WIRE_RUN_ID"] ?? environment["AXOLOTY_RUN_ID"] {
                overlay["WIRE_RUN_ID"] = runID
            }
            return rewrite(
                plan,
                substitutions: [
                    ".testing/wire": outputDirectory,
                    ".testing/wire/manifest.json": "\(outputDirectory)/manifest.json",
                ],
                environment: overlay
            )
        }
    }

    func command(_ request: CanonicalCommandRequest) throws -> AxolotyCommandPlan {
        try validateManifest()
        switch request {
        case .node(let name):
            return command(for: try node(named: name))
        case .testOne(let filter):
            return command(
                from: manifest.testOne.command,
                filter: filter,
                timeoutSeconds: manifest.testOne.timeoutSeconds
            )
        case .testOneOrNode(let value, let platform):
            if let node = manifest.nodes.first(where: { $0.id == value }),
               node.filter == nil,
               node.local,
               node.isAvailable(on: platform) {
                return command(for: node)
            }
            return command(
                from: manifest.testOne.command,
                filter: value,
                timeoutSeconds: manifest.testOne.timeoutSeconds
            )
        case .timing(let scenario, let mode, let workspace, let filter):
            let base: AxolotyCommandPlan = switch scenario {
            case .hostBuild:
                try command(.node(name: "build"))
            case .focusedTestBuild:
                try command(.testOne(filter: filter))
            case .embeddedBuild:
                try command(.node(name: "embedded-build"))
            case .linkerValidation:
                try command(.node(name: "embedded-linker"))
            }
            var arguments = base.arguments
            var environment = base.environment
            environment["AXOLOTY_TIMING_SCENARIO"] = scenario.rawValue
            environment["AXOLOTY_TIMING_MODE"] = mode.rawValue
            environment["AXOLOTY_TIMING_SCRATCH"] = workspace
            switch scenario {
            case .hostBuild, .focusedTestBuild:
                if !arguments.contains("--scratch-path") {
                    arguments += ["--scratch-path", workspace]
                }
            case .embeddedBuild:
                environment["EMBEDDED_BUILD_DIR"] = workspace
                environment["AXOLOTY_TIMING_EVIDENCE"] = "1"
            case .linkerValidation:
                environment["AXOLOTY_EMBEDDED_LINKER_BUILD_DIR"] = workspace
                environment["AXOLOTY_TIMING_EVIDENCE"] = "1"
            }
            return AxolotyCommandPlan(
                executable: base.executable,
                arguments: arguments,
                environment: environment,
                executionContext: base.executionContext,
                timeoutSeconds: base.timeoutSeconds
            )
        }
    }

    func explanation(
        for request: CanonicalPlanRequest
    ) throws -> AxolotyCanonicalTestExplanation {
        let plan = try resolve(request)
        let name: String
        let ci: Bool
        switch request {
        case .tier(let tier, let selectedCI, _, _):
            name = tier
            ci = selectedCI
        case .checkpoint:
            name = CanonicalTier.release.rawValue
            ci = false
        case .wireCapture:
            name = CanonicalTier.wire.rawValue
            ci = false
        }
        let byID = Dictionary(uniqueKeysWithValues: manifest.nodes.map { ($0.id, $0) })
        let nodes = plan.nodes.compactMap { checkNode -> AxolotyCanonicalTestNodeExplanation? in
            guard let node = byID[checkNode.name] else { return nil }
            return AxolotyCanonicalTestNodeExplanation(
                id: node.id,
                dependencies: node.dependencies,
                executable: checkNode.command.executable,
                arguments: checkNode.command.arguments,
                timeoutSeconds: node.timeoutSeconds,
                expectedDurationSeconds: node.expectedDurationSeconds,
                network: node.network,
                broker: node.broker,
                hardware: node.hardware,
                resources: node.resources,
                isolation: node.isolation,
                lane: node.lane,
                artifacts: node.artifacts
            )
        }
        return AxolotyCanonicalTestExplanation(
            schemaVersion: manifest.schemaVersion,
            name: name,
            ci: ci,
            timeoutSeconds: plan.deadlineSeconds,
            nodes: nodes
        )
    }

    private func resolveTier(
        _ name: String,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform,
        requested: [String]? = nil
    ) throws -> AxolotyCheckPlan {
        guard let definition = manifest.tiers.first(where: { $0.id == name }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        // A category that declares it needs no hardware must not contain a node
        // that does; that is the whole basis on which a host decides it can run
        // the category at all.
        if definition.hardware == .forbidden {
            for root in definition.nodes {
                if let node = manifest.nodes.first(where: { $0.id == root }), node.hardware != .forbidden {
                    throw AxolotyCanonicalTestManifestError.invalidPlan(
                        name: name,
                        reason: "hardware node \(root) is forbidden in the \(name) category"
                    )
                }
            }
        }
        let availability: @Sendable (AxolotyCanonicalTestNode) -> Bool = { ci ? $0.ci : $0.local }
        let declaredPlan = try resolve(
            roots: definition.nodes,
            platform: platform,
            availability: availability,
            deadlineSeconds: definition.timeoutSeconds,
            expectedDurationSeconds: definition.expectedDurationSeconds
        )
        guard let requested else { return declaredPlan }
        let available = Set(declaredPlan.nodes.map(\.name))
        guard requested.allSatisfy(available.contains) else {
            throw AxolotyCanonicalTestManifestError.unavailableNode(
                requested.first { !available.contains($0) } ?? name
            )
        }
        return try resolve(
            roots: requested,
            platform: platform,
            availability: availability,
            deadlineSeconds: definition.timeoutSeconds,
            expectedDurationSeconds: definition.expectedDurationSeconds
        )
    }

    private func validateManifest() throws {
        guard manifest.schemaVersion == AxolotyCanonicalTestManifest.currentSchemaVersion else {
            throw AxolotyCanonicalTestManifestError.unsupportedSchema(manifest.schemaVersion)
        }
    }

    private func resolve(
        roots: [String],
        platform: AxolotyCheckPlan.Platform,
        availability: (AxolotyCanonicalTestNode) -> Bool,
        deadlineSeconds: TimeInterval?,
        expectedDurationSeconds: TimeInterval? = nil
    ) throws -> AxolotyCheckPlan {
        let available = manifest.nodes.filter { $0.isAvailable(on: platform) && availability($0) }
        for root in roots {
            guard manifest.nodes.contains(where: { $0.id == root }) else {
                throw AxolotyCanonicalTestManifestError.unavailableNode(root)
            }
        }
        let availableRoots = roots.filter { root in
            guard let node = manifest.nodes.first(where: { $0.id == root }) else {
                return false
            }
            return node.isAvailable(on: platform) && availability(node)
        }
        return try AxolotyCheckPlanner().plan(
            available.map { checkNode(from: $0) },
            requested: availableRoots,
            deadlineSeconds: deadlineSeconds,
            expectedDurationSeconds: expectedDurationSeconds
        )
    }

    private func node(named name: String) throws -> AxolotyCanonicalTestNode {
        guard let node = manifest.nodes.first(where: { $0.id == name }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        return node
    }

    private func checkNode(from node: AxolotyCanonicalTestNode) -> AxolotyCheckNode {
        AxolotyCheckNode(
            name: node.id,
            dependencies: node.dependencies,
            command: command(
                from: node.command,
                filter: node.filter,
                timeoutSeconds: node.timeoutSeconds
            ),
            resources: node.resources,
            expectedDurationSeconds: node.expectedDurationSeconds
        )
    }

    private func command(for node: AxolotyCanonicalTestNode) -> AxolotyCommandPlan {
        command(
            from: node.command,
            filter: node.filter,
            timeoutSeconds: node.timeoutSeconds
        )
    }

    private func command(
        from specification: AxolotyCanonicalTestCommand,
        filter: String?,
        timeoutSeconds: TimeInterval?
    ) -> AxolotyCommandPlan {
        var arguments = specification.arguments
        if let filterFlag = specification.filterFlag, let filter {
            if let flagIndex = arguments.firstIndex(of: filterFlag),
               arguments.index(after: flagIndex) < arguments.endIndex {
                arguments[arguments.index(after: flagIndex)] = filter
            } else {
                arguments.append(contentsOf: [filterFlag, filter])
            }
        }
        return AxolotyCommandPlan(
            executable: specification.executable,
            arguments: arguments,
            environment: specification.environment,
            executionContext: specification.executionContext,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func rewrite(
        _ plan: AxolotyCheckPlan,
        substitutions: [String: String],
        environment: [String: String] = [:]
    ) -> AxolotyCheckPlan {
        AxolotyCheckPlan(
            nodes: plan.nodes.map { node in
                AxolotyCheckNode(
                    name: node.name,
                    dependencies: node.dependencies,
                    command: AxolotyCommandPlan(
                        executable: node.command.executable,
                        arguments: node.command.arguments.map { substitutions[$0] ?? $0 },
                        environment: node.command.environment.merging(environment) { _, value in value },
                        executionContext: node.command.executionContext,
                        timeoutSeconds: node.command.timeoutSeconds
                    ),
                    resources: node.resources,
                    expectedDurationSeconds: node.expectedDurationSeconds
                )
            },
            deadlineSeconds: plan.deadlineSeconds,
            expectedDurationSeconds: plan.expectedDurationSeconds
        )
    }

    private static func loadManifest(
        environment: [String: String]
    ) throws -> AxolotyCanonicalTestManifest {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let currentRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundledManifest = Bundle.module.url(forResource: "test-tiers", withExtension: "json")
        let candidates = [
            environment["AXOLOTY_TEST_MANIFEST"].flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path, relativeTo: currentRoot)
            },
            currentRoot.appending(path: "Tests/Support/test-tiers.json"),
            sourceRoot.appending(path: "Tests/Support/test-tiers.json"),
            bundledManifest,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try loadManifest(from: candidate)
        }
        throw AxolotyCanonicalTestManifestError.notFound(candidates.map(\.path))
    }

    private static func loadManifest(
        from url: URL
    ) throws -> AxolotyCanonicalTestManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AxolotyCanonicalTestManifestError.notFound([url.path])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AxolotyCanonicalTestManifestError.unreadable(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        let manifest: AxolotyCanonicalTestManifest
        do {
            manifest = try JSONDecoder().decode(AxolotyCanonicalTestManifest.self, from: data)
        } catch {
            throw AxolotyCanonicalTestManifestError.decodingFailure(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        guard manifest.schemaVersion == AxolotyCanonicalTestManifest.currentSchemaVersion else {
            throw AxolotyCanonicalTestManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }
}
