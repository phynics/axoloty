// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs the explicit, serial, hardware-free timing evidence command.
public struct AxolotyTimingRunner: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let environment: [String: String]
    private let platform: AxolotyCheckPlan.Platform
    private let workspace: any AxolotyTimingWorkspaceManaging
    private let clock: any AxolotyTimingClock
    private let cacheReader: any AxolotyTimingCacheStatsReading
    private let identity: AxolotyTimingToolchainIdentity
    private let planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>

    /// Creates a timing runner with injectable process, clock, workspace, and cache seams.
    ///
    /// - Parameters:
    ///   - commandRunner: Process runner used for each serialized measurement.
    ///   - environment: Environment used to resolve the manifest and defaults.
    ///   - platform: Platform boundary for Linux-only measurements.
    ///   - workspace: Isolated scratch-directory manager.
    ///   - clock: Monotonic timing source.
    ///   - cacheReader: Optional externally sampled cache-counter source.
    ///   - identity: Optional deterministic toolchain identity.
    public init(
        commandRunner: any AxolotyCheckCommandRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        workspace: any AxolotyTimingWorkspaceManaging = FoundationTimingWorkspaceManager(),
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock(),
        cacheReader: (any AxolotyTimingCacheStatsReading)? = nil,
        identity: AxolotyTimingToolchainIdentity? = nil
    ) {
        let planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
        do {
            planResolver = .success(try AxolotyCanonicalTestPlanResolver(environment: environment))
        } catch let error as AxolotyCanonicalTestManifestError {
            planResolver = .failure(error)
        } catch {
            planResolver = .failure(.decodingFailure(
                path: environment["AXOLOTY_TEST_MANIFEST"] ?? "canonical test manifest",
                reason: error.localizedDescription
            ))
        }
        self.init(
            commandRunner: commandRunner,
            environment: environment,
            platform: platform,
            workspace: workspace,
            clock: clock,
            cacheReader: cacheReader,
            identity: identity,
            planResolver: planResolver
        )
    }

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        environment: [String: String],
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        workspace: any AxolotyTimingWorkspaceManaging = FoundationTimingWorkspaceManager(),
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock(),
        cacheReader: (any AxolotyTimingCacheStatsReading)? = nil,
        identity: AxolotyTimingToolchainIdentity? = nil,
        planResolver: Result<AxolotyCanonicalTestPlanResolver, AxolotyCanonicalTestManifestError>
    ) {
        self.commandRunner = commandRunner
        self.environment = environment
        self.platform = platform
        self.workspace = workspace
        self.clock = clock
        self.cacheReader = cacheReader ?? UnavailableTimingCacheReader()
        self.identity = identity ?? AxolotyTimingToolchainIdentity.current(environment: environment)
        self.planResolver = planResolver
    }

    /// Runs cold and warm measurements for each supported scenario in stable order.
    ///
    /// - Parameter options: Timing filter and scratch-retention options.
    /// - Returns: Complete machine-readable evidence report.
    public func run(_ options: AxolotyTimingOptions) -> AxolotyTimingReport {
        let root = options.scratchRoot
            ?? environment["AXOLOTY_TIMING_SCRATCH_ROOT"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".testing/timing", isDirectory: true).path
        guard platform == .linux else {
            return AxolotyTimingReport(
                platform: platform,
                toolchain: identity,
                scratchRoot: root,
                keepScratch: options.keepScratch,
                measurements: [],
                exitCode: 69,
                diagnostic: "measure timing is supported only on Linux"
            )
        }
        let resolver: AxolotyCanonicalTestPlanResolver
        do {
            resolver = try planResolver.get()
        } catch {
            return AxolotyTimingReport(
                platform: platform,
                toolchain: identity,
                scratchRoot: root,
                keepScratch: options.keepScratch,
                measurements: [],
                exitCode: 70,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(error.userFriendlyMessage)
            )
        }

        var measurements: [AxolotyTimingMeasurement] = []
        var cleanupDiagnostics: [String] = []
        for scenario in AxolotyTimingScenario.allCases {
            for mode in [AxolotyTimingMode.cold, .warm] {
                let prepared = workspace.prepare(root: root, scenario: scenario, mode: mode)
                let measurement = measure(
                    scenario: scenario,
                    mode: mode,
                    workspace: prepared,
                    resolver: resolver,
                    filter: options.filter
                )
                measurements.append(measurement)
            }
            if !options.keepScratch, let workspaceState = measurements.last(where: { $0.scenario == scenario }) {
                if let diagnostic = workspace.cleanup(AxolotyTimingWorkspace(path: workspaceState.scratchPath)) {
                    cleanupDiagnostics.append(diagnostic)
                }
            }
        }
        let measurementFailed = measurements.contains { $0.exitCode != 0 }
        let failed = measurementFailed || !cleanupDiagnostics.isEmpty
        let diagnostic: String? = if !cleanupDiagnostics.isEmpty {
            AxolotyTimingOutputParser.boundedDiagnostic(cleanupDiagnostics.joined(separator: "; "))
        } else if measurementFailed {
            "one or more timing measurements failed"
        } else {
            nil
        }
        return AxolotyTimingReport(
            platform: platform,
            toolchain: identity,
            scratchRoot: root,
            keepScratch: options.keepScratch,
            measurements: measurements,
            exitCode: failed ? 1 : 0,
            diagnostic: diagnostic
        )
    }

    private func measure(
        scenario: AxolotyTimingScenario,
        mode: AxolotyTimingMode,
        workspace: AxolotyTimingWorkspace,
        resolver: AxolotyCanonicalTestPlanResolver,
        filter: String
    ) -> AxolotyTimingMeasurement {
        let commandResult = commandPlan(
            scenario: scenario,
            workspace: workspace.path,
            resolver: resolver,
            filter: filter,
            mode: mode
        )
        let command: AxolotyCommandPlan
        switch commandResult {
        case .success(let plan):
            command = plan
        case .failure(let error):
            return AxolotyTimingMeasurement(
                scenario: scenario, mode: mode, durationSeconds: 0, exitCode: 70,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(error.userFriendlyMessage),
                buildSteps: AxolotyTimingMetric(unavailable: "command unavailable"),
                cache: AxolotyTimingCacheStats(hits: nil, misses: nil),
                scratchReused: workspace.reused, scratchPath: workspace.path,
                command: AxolotyCommandPlan(executable: "unavailable"), toolchain: identity
            )
        }
        guard workspace.diagnostic == nil else {
            return AxolotyTimingMeasurement(
                scenario: scenario, mode: mode, durationSeconds: 0, exitCode: 70,
                diagnostic: workspace.diagnostic,
                buildSteps: AxolotyTimingMetric(unavailable: "workspace unavailable"),
                cache: AxolotyTimingCacheStats(hits: nil, misses: nil),
                scratchReused: workspace.reused, scratchPath: workspace.path,
                command: command, toolchain: identity
            )
        }
        let before = cacheReader.read()
        let start = clock.now()
        let result = commandRunner.run(command)
        let duration = max(0, clock.now() - start)
        let after = cacheReader.read()
        let output = result.standardOutput + "\n" + result.standardError
        let cache = cacheStats(before: before, after: after, output: output)
        return AxolotyTimingMeasurement(
            scenario: scenario,
            mode: mode,
            durationSeconds: duration,
            exitCode: result.exitCode,
            diagnostic: result.exitCode == 0
                ? nil
                : AxolotyTimingOutputParser.boundedDiagnostic(result.standardError.isEmpty ? result.standardOutput : result.standardError),
            buildSteps: AxolotyTimingOutputParser.stepMetric(from: output),
            cache: cache,
            scratchReused: workspace.reused,
            scratchPath: workspace.path,
            command: command,
            toolchain: identity
        )
    }

    private func commandPlan(
        scenario: AxolotyTimingScenario,
        workspace: String,
        resolver: AxolotyCanonicalTestPlanResolver,
        filter: String,
        mode: AxolotyTimingMode
    ) -> Result<AxolotyCommandPlan, AxolotyCanonicalTestManifestError> {
        do {
            return .success(try resolver.command(.timing(
                scenario: scenario,
                mode: mode,
                workspace: workspace,
                filter: filter
            )))
        } catch let error as AxolotyCanonicalTestManifestError {
            return .failure(error)
        } catch {
            return .failure(.invalidPlan(
                name: scenario.rawValue,
                reason: "unexpected canonical manifest error: \(String(reflecting: error))"
            ))
        }
    }

    private func cacheStats(
        before: AxolotyTimingCacheSnapshot?,
        after: AxolotyTimingCacheSnapshot?,
        output: String
    ) -> AxolotyTimingCacheStats {
        if let before, let after {
            return AxolotyTimingCacheStats(
                hits: max(0, after.hits - before.hits),
                misses: max(0, after.misses - before.misses),
                diagnostic: "sampled before and after command"
            )
        }
        return AxolotyTimingOutputParser.cacheMetric(from: output)
    }
}
