// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum CanonicalNamedPlan: String, CaseIterable, Sendable {
    case offline
    case verify
    case checkpoint
    case checkpointHardware = "checkpoint-hardware"
    case wireLive = "wire-live"
    case testTooling = "test-tooling"
    case objectModel = "object-model"
    case g4Runtime = "g4-runtime"
    case g5OptionalProducts = "g5-optional-products"
}

enum CanonicalPlanRequest: Sendable {
    case named(
        CanonicalNamedPlan,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform,
        requested: [String]?
    )
    case tier(
        name: String,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform
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
        case .named(let name, let ci, let platform, let requested):
            return try resolveNamed(
                name,
                ci: ci,
                platform: platform,
                requested: requested
            )
        case .tier(let name, let ci, let platform):
            return try resolveTier(name, ci: ci, platform: platform)
        case .checkpoint(let hardwareDevice, let consumerEnvironment, let platform):
            let plan = try resolveNamed(
                hardwareDevice == nil ? .checkpoint : .checkpointHardware,
                ci: false,
                platform: platform,
                requested: nil
            )
            var environment = consumerEnvironment
            if let hardwareDevice {
                environment["EMBEDDED_DEVICE"] = hardwareDevice
            }
            return rewrite(plan, substitutions: [:], environment: environment)
        case .wireCapture(let environment, let platform):
            let plan = try resolveNamed(
                .wireLive,
                ci: false,
                platform: platform,
                requested: nil
            )
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
        case .named(let named, let selectedCI, _, _):
            name = named.rawValue
            ci = selectedCI
        case .tier(let tier, let selectedCI, _):
            name = tier
            ci = selectedCI
        case .checkpoint(let hardwareDevice, _, _):
            name = hardwareDevice == nil
                ? CanonicalNamedPlan.checkpoint.rawValue
                : CanonicalNamedPlan.checkpointHardware.rawValue
            ci = false
        case .wireCapture:
            name = CanonicalNamedPlan.wireLive.rawValue
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
        platform: AxolotyCheckPlan.Platform
    ) throws -> AxolotyCheckPlan {
        guard let definition = manifest.tiers.first(where: { $0.id == name }) else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        return try resolve(
            roots: definition.nodes,
            platform: platform,
            availability: { ci ? $0.ci : $0.local },
            deadlineSeconds: definition.timeoutSeconds,
            expectedDurationSeconds: definition.expectedDurationSeconds
        )
    }

    private func validateManifest() throws {
        guard manifest.schemaVersion == AxolotyCanonicalTestManifest.currentSchemaVersion else {
            throw AxolotyCanonicalTestManifestError.unsupportedSchema(manifest.schemaVersion)
        }
    }

    private func resolveNamed(
        _ name: CanonicalNamedPlan,
        ci: Bool,
        platform: AxolotyCheckPlan.Platform,
        requested: [String]?
    ) throws -> AxolotyCheckPlan {
        guard let definition = manifest.plans[name.rawValue] else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name.rawValue)
        }
        let declaredRoots = try inheritedRoots(for: name.rawValue, ci: ci, stack: [])
        let roots: [String]
        if name == .verify {
            roots = manifest.requiredGates + (ci ? manifest.ciRequiredGates : [])
            if !declaredRoots.isEmpty, declaredRoots != roots {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name.rawValue,
                    reason: "verify roots must be derived from requiredGates and ciRequiredGates"
                )
            }
        } else {
            roots = declaredRoots
        }
        if name == .checkpointHardware {
            guard definition.inherits == CanonicalNamedPlan.checkpoint.rawValue else {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name.rawValue,
                    reason: "checkpoint-hardware must inherit checkpoint"
                )
            }
            let ordinary = Set(try inheritedRoots(
                for: CanonicalNamedPlan.checkpoint.rawValue,
                ci: ci,
                stack: []
            ))
            let hardware = Set(roots)
            guard ordinary.isSubset(of: hardware), hardware.count > ordinary.count else {
                throw AxolotyCanonicalTestManifestError.invalidPlan(
                    name: name.rawValue,
                    reason: "checkpoint-hardware must be a strict superset of checkpoint"
                )
            }
        }
        if name == .verify || name == .offline {
            for root in roots {
                if let node = manifest.nodes.first(where: { $0.id == root }),
                   node.hardware != .forbidden {
                    throw AxolotyCanonicalTestManifestError.invalidPlan(
                        name: name.rawValue,
                        reason: "hardware node \(root) is forbidden in ordinary/offline plans"
                    )
                }
            }
        }
        let declaredPlan = try resolve(
            roots: roots,
            platform: platform,
            availability: { ci ? $0.ci : $0.local },
            deadlineSeconds: definition.timeoutSeconds,
            expectedDurationSeconds: definition.expectedDurationSeconds
        )
        guard let requested else { return declaredPlan }
        let availableNodeNames = Set(declaredPlan.nodes.map(\.name))
        guard requested.allSatisfy(availableNodeNames.contains) else {
            let unavailable = requested.first { !availableNodeNames.contains($0) }
                ?? name.rawValue
            throw AxolotyCanonicalTestManifestError.unavailableNode(unavailable)
        }
        return try resolve(
            roots: requested,
            platform: platform,
            availability: { ci ? $0.ci : $0.local },
            deadlineSeconds: definition.timeoutSeconds,
            expectedDurationSeconds: definition.expectedDurationSeconds
        )
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

    private func inheritedRoots(
        for name: String,
        ci: Bool,
        stack: [String]
    ) throws -> [String] {
        guard let definition = manifest.plans[name] else {
            throw AxolotyCanonicalTestManifestError.unknownEntry(name)
        }
        guard !stack.contains(name) else {
            throw AxolotyCanonicalTestManifestError.planInheritanceCycle(stack + [name])
        }
        let localRoots = ci ? (definition.ciNodes ?? definition.nodes) : definition.nodes
        guard let parent = definition.inherits else { return localRoots }
        guard manifest.plans[parent] != nil else {
            throw AxolotyCanonicalTestManifestError.missingPlanInheritance(
                plan: name,
                parent: parent
            )
        }
        return try inheritedRoots(for: parent, ci: ci, stack: stack + [name]) + localRoots
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
