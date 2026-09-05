// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private let timingTestEnvironment = [
    "AXOLOTY_DEVCONTAINER": "1",
]

private final class TimingRecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    private(set) var commands: [AxolotyCommandPlan] = []
    var result = AxolotyCheckCommandResult(
        exitCode: 0,
        standardOutput: "[1/7] Compiling TimingFixture\nCache hits: 5\nCache misses: 2\n"
    )

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commands.append(command)
        return result
    }
}

private final class TimingRecordingClock: AxolotyTimingClock, @unchecked Sendable {
    private var nextValue: TimeInterval

    init(start: TimeInterval = 10) {
        nextValue = start
    }

    func now() -> TimeInterval {
        defer { nextValue += 0.25 }
        return nextValue
    }
}

private final class TimingRecordingWorkspace: AxolotyTimingWorkspaceManaging, @unchecked Sendable {
    private(set) var prepared: [(AxolotyTimingScenario, AxolotyTimingMode)] = []
    private(set) var cleaned: [String] = []

    func prepare(
        root: String,
        scenario: AxolotyTimingScenario,
        mode: AxolotyTimingMode
    ) -> AxolotyTimingWorkspace {
        prepared.append((scenario, mode))
        return AxolotyTimingWorkspace(
            path: "\(root)/\(scenario.rawValue)",
            reused: mode == .warm
        )
    }

    func cleanup(_ workspace: AxolotyTimingWorkspace) -> String? {
        cleaned.append(workspace.path)
        return nil
    }
}

private final class TimingSequenceCacheReader: AxolotyTimingCacheStatsReading, @unchecked Sendable {
    private let snapshots: [AxolotyTimingCacheSnapshot?]
    private var index = 0

    init(snapshots: [AxolotyTimingCacheSnapshot?]) {
        self.snapshots = snapshots
    }

    func read() -> AxolotyTimingCacheSnapshot? {
        defer { index += 1 }
        return snapshots[min(index, snapshots.count - 1)]
    }
}

@Test
func timingArgumentParserAcceptsFilterScratchRootAndKeep() throws {
    let parsed = AxolotyTimingArgumentParser.parse([
        "--filter", "AxolotyTimingTests", "--scratch-root", "/tmp/timing", "--keep-scratch",
    ])

    let options = try #require(parsed.success)
    #expect(options.filter == "AxolotyTimingTests")
    #expect(options.scratchRoot == "/tmp/timing")
    #expect(options.keepScratch)
}

@Test
func timingArgumentParserRejectsUnknownAndMissingValues() {
    #expect(AxolotyTimingArgumentParser.parse(["--unknown"]).failure == .unsupportedOption("--unknown"))
    #expect(AxolotyTimingArgumentParser.parse(["--filter"]).failure == .missingValue("--filter"))
}

@Test
func timingParsersReportBuildStepsAndCacheStatsWithoutGuessing() {
    let steps = AxolotyTimingOutputParser.stepMetric(from: "[1/12] Compiling Alpha\n[12/12] Linking App\n")
    #expect(steps.status == .available)
    #expect(steps.value == 12)

    let cache = AxolotyTimingOutputParser.cacheMetric(from: "Cache hits: 9\nCache misses: 3\n")
    #expect(cache.status == .available)
    #expect(cache.value == 12)
    #expect(cache.diagnostic?.contains("hits=9") == true)

    let ccache = AxolotyTimingOutputParser.cacheMetric(from: "direct_cache_hit 19\npreprocessed_cache_hit 8\ncache_miss\t4\n")
    #expect(ccache.hits == 27)
    #expect(ccache.misses == 4)

    let delta = AxolotyTimingOutputParser.cacheMetric(from: """
    ccache_before direct_cache_hit 10
    ccache_before preprocessed_cache_hit 2
    ccache_before cache_miss 7
    ccache_after direct_cache_hit 14
    ccache_after preprocessed_cache_hit 3
    ccache_after cache_miss 9
    """)
    #expect(delta.hits == 5)
    #expect(delta.misses == 2)

    let unavailable = AxolotyTimingOutputParser.stepMetric(from: "Build complete! (0.12s)\n")
    #expect(unavailable.status == .unavailable)
    #expect(unavailable.value == nil)
}

@Test
func timingRunnerBuildsEightSerialHardwareFreePlansWithIsolatedScratch() throws {
    let runner = TimingRecordingRunner()
    let workspace = TimingRecordingWorkspace()
    let timing = AxolotyTimingRunner(
        commandRunner: runner,
        environment: timingTestEnvironment,
        workspace: workspace,
        clock: TimingRecordingClock(),
        cacheReader: TimingSequenceCacheReader(snapshots: (0..<16).map { index in
            index.isMultiple(of: 2)
                ? AxolotyTimingCacheSnapshot(hits: 10, misses: 20)
                : AxolotyTimingCacheSnapshot(hits: 13, misses: 21)
        }),
        identity: AxolotyTimingToolchainIdentity(
            platform: "linux",
            architecture: "test-arch",
            swiftVersion: "Swift test",
            espIDFVersion: "ESP-IDF test"
        )
    )

    let report = timing.run(AxolotyTimingOptions(
        filter: "AxolotyTimingTests",
        scratchRoot: "/tmp/timing",
        keepScratch: true
    ))

    #expect(report.exitCode == 0)
    #expect(report.measurements.count == 8)
    #expect(runner.commands.count == 8)
    #expect(workspace.prepared.map { $0.1 } == [.cold, .warm, .cold, .warm, .cold, .warm, .cold, .warm])
    #expect(workspace.cleaned.isEmpty)
    #expect(report.measurements.allSatisfy { $0.durationSeconds == 0.25 })
    #expect(report.measurements.allSatisfy { $0.toolchain.platform == "linux" })
    #expect(report.measurements.allSatisfy { $0.cache.hits == 3 && $0.cache.misses == 1 })

    let hostBuild = try #require(runner.commands.first)
    #expect(hostBuild.executable == "swift")
    #expect(hostBuild.arguments == [
        "build", "-Xswiftc", "-warnings-as-errors", "--cache-path", ".swiftpm-cache",
        "--disable-automatic-resolution", "--scratch-path", "/tmp/timing/host-build",
    ])
    #expect(hostBuild.environment["AXOLOTY_TIMING_SCENARIO"] == "host-build")
    #expect(hostBuild.environment["AXOLOTY_TIMING_MODE"] == "cold")

    let focused = try #require(runner.commands.first {
        $0.environment["AXOLOTY_TIMING_SCENARIO"] == "focused-test-build"
    })
    #expect(focused.executable == "swift")
    #expect(focused.arguments == [
        "test", "-Xswiftc", "-warnings-as-errors", "--cache-path", ".swiftpm-cache",
        "--disable-automatic-resolution", "--filter", "AxolotyTimingTests",
        "--scratch-path", "/tmp/timing/focused-test-build",
    ])

    let embeddedBuild = try #require(runner.commands.first { $0.environment["AXOLOTY_TIMING_SCENARIO"] == "embedded-build" })
    #expect(embeddedBuild.executable == "Tests/Support/embedded/build-embedded-swift.sh")
    #expect(embeddedBuild.arguments.isEmpty)
    #expect(embeddedBuild.executionContext == .project)
    #expect(embeddedBuild.environment["EMBEDDED_BUILD_DIR"]?.hasSuffix("/embedded-build") == true)
    #expect(embeddedBuild.environment["AXOLOTY_TIMING_MODE"] == "cold")
    #expect(embeddedBuild.environment["AXOLOTY_TIMING_EVIDENCE"] == "1")

    let linker = try #require(runner.commands.first { $0.environment["AXOLOTY_TIMING_SCENARIO"] == "linker-validation" })
    #expect(linker.executable == "Tests/Support/checks/check-embedded-swift-linker.sh")
    #expect(linker.arguments.isEmpty)
    #expect(linker.executionContext == .project)
    #expect(linker.environment["AXOLOTY_EMBEDDED_LINKER_BUILD_DIR"]?.hasSuffix("/linker-validation") == true)
    #expect(linker.environment["AXOLOTY_TIMING_EVIDENCE"] == "1")
    #expect(linker.environment["EMBEDDED_DEVICE"] == nil)
}

@Test
func timingRunnerCleansScratchWhenKeepIsDisabledAndBoundsFailureDiagnostics() {
    let runner = TimingRecordingRunner()
    runner.result = AxolotyCheckCommandResult(
        exitCode: 23,
        standardError: String(repeating: "failure detail ", count: 200)
    )
    let workspace = TimingRecordingWorkspace()
    let timing = AxolotyTimingRunner(
        commandRunner: runner,
        environment: timingTestEnvironment,
        workspace: workspace,
        clock: TimingRecordingClock(),
        identity: .init(platform: "linux", architecture: "test", swiftVersion: "unknown", espIDFVersion: "unknown")
    )

    let report = timing.run(AxolotyTimingOptions(
        filter: "AxolotyTimingTests",
        scratchRoot: "/tmp/timing",
        keepScratch: false
    ))

    #expect(report.exitCode == 1)
    #expect(report.measurements.allSatisfy { $0.exitCode == 23 })
    #expect(report.measurements.allSatisfy { ($0.diagnostic?.count ?? 0) <= 512 })
    #expect(workspace.cleaned.count == 4)
}

@Test
func timingRunnerRejectsUnsupportedPlatformsBeforeLaunchingCommands() {
    let runner = TimingRecordingRunner()
    let timing = AxolotyTimingRunner(
        commandRunner: runner,
        environment: timingTestEnvironment,
        platform: .macOS,
        identity: .init(platform: "macOS", architecture: "test", swiftVersion: "unknown", espIDFVersion: "unknown")
    )

    let report = timing.run(AxolotyTimingOptions(scratchRoot: "/tmp/timing"))

    #expect(report.exitCode == 69)
    #expect(report.measurements.isEmpty)
    #expect(runner.commands.isEmpty)
    #expect(report.diagnostic?.contains("Linux") == true)
}

@Test
func dispatcherExposesTimingAsSortedJSONAndRejectsInvalidCLIOptions() throws {
    let runner = TimingRecordingRunner()
    let timing = AxolotyTimingRunner(
        commandRunner: runner,
        environment: timingTestEnvironment,
        workspace: TimingRecordingWorkspace(),
        clock: TimingRecordingClock(),
        identity: .init(platform: "linux", architecture: "test", swiftVersion: "test", espIDFVersion: "test")
    )
    let dispatcher = AxolotyCommandDispatcher(
        commandRunner: runner,
        environment: timingTestEnvironment,
        timingRunner: timing,
        installSignalHandler: false
    )

    let result = dispatcher.run(arguments: [
        "measure", "timing", "--filter", "AxolotyTimingTests", "--keep-scratch",
    ])
    let document = try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
    let measurements = try #require(document["measurements"] as? [[String: Any]])
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    #expect(measurements.count == 8)
    #expect(result.standardOutput.firstIndex(of: "\n") != nil)
    let exitCodeKey = try #require(result.standardOutput.range(of: "\"exitCode\""))
    let measurementsKey = try #require(result.standardOutput.range(of: "\"measurements\""))
    #expect(exitCodeKey.lowerBound < measurementsKey.lowerBound)

    let invalid = dispatcher.run(arguments: ["measure", "timing", "--not-an-option"])
    #expect(invalid.exitCode == 64)
    #expect(invalid.standardError.contains("unsupported timing option"))
}
