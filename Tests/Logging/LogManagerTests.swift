// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Logging
import Testing

/// Captures the `LogEvent`s a test-scoped `Logger` emits so assertions can
/// inspect level and metadata without going through `AxolotyLogHandler`'s
/// real `StreamLogHandler` (which always writes to stderr -- see
/// `LogManager`'s doc comment for why the level-proxy design requires that).
/// Otherwise mirrors `AxolotyLogHandler` exactly: `logLevel` reads/writes
/// through `LogManager`'s internal, label-keyed level store, which is the
/// behavior under test.
private struct CapturingLogHandler: LogHandler {
    let subsystemLabel: String
    let box: CaptureBox
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?

    var logLevel: Logging.Logger.Level {
        get { LogManager.level(for: subsystemLabel) }
        set { LogManager.setLevel(newValue, forSubsystemLabel: subsystemLabel) }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        box.append(level: event.level, message: "\(event.message)", metadata: event.metadata ?? [:])
    }
}

private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: Logging.Logger.Level, message: String, metadata: Logging.Logger.Metadata)] = []

    func append(level: Logging.Logger.Level, message: String, metadata: Logging.Logger.Metadata) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((level, message, metadata))
    }

    func snapshot() -> [(level: Logging.Logger.Level, message: String, metadata: Logging.Logger.Metadata)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private func makeCapturingLogger(subsystemLabel: String, box: CaptureBox) -> Logging.Logger {
    Logging.Logger(label: "test.\(subsystemLabel)") { _ in
        CapturingLogHandler(subsystemLabel: subsystemLabel, box: box)
    }
}

/// Resets a test-scoped subsystem label's level back to whatever it was
/// before the test ran, so level changes don't leak across tests sharing
/// `LogManager`'s process-global store.
private func withIsolatedSubsystemLevel(_ label: String, _ body: () async throws -> Void) async rethrows {
    let original = LogManager.level(for: label)
    defer { LogManager.setLevel(original, forSubsystemLabel: label) }
    try await body()
}

/// Restores the process-global default level after a test, including when its
/// assertion fails. Default-level tests must run without peer tests because
/// `Container.resolve` intentionally updates this same application setting.
private func withIsolatedDefaultLevel(_ body: () throws -> Void) rethrows {
    let original = LogManager.defaultLevel
    defer { LogManager.defaultLevel = original }
    try body()
}

struct LogManagerTests {
    @Test
    func levelGatingSuppressesBelowThresholdAndPassesThroughAtOrAboveIt() async throws {
        await withIsolatedSubsystemLevel("test.levelGating") {
            let box = CaptureBox()
            LogManager.setLevel(.info, forSubsystemLabel: "test.levelGating")
            let logger = makeCapturingLogger(subsystemLabel: "test.levelGating", box: box)

            logger.debug("suppressed: below threshold")
            logger.notice("passes: notice is above info")
            logger.warning("passes: warning is above info")

            let entries = box.snapshot()
            #expect(entries.count == 2)
            #expect(entries.map(\.level) == [.notice, .warning])
        }
    }

    /// Regression guard for the exact bug #140 fixes: a level change made
    /// after a `Logger` has already been vended and stored (as every call
    /// site in this codebase does, e.g. `private let log = LogManager.logger(...)`)
    /// must still take effect, because `logLevel` is read live from
    /// `LogManager`'s store on every log call rather than baked in at vend
    /// time.
    @Test
    func dynamicLevelChangeIsObservedByAnAlreadyVendedLogger() async throws {
        await withIsolatedSubsystemLevel("test.dynamicLevel") {
            let box = CaptureBox()
            LogManager.setLevel(.error, forSubsystemLabel: "test.dynamicLevel")
            let logger = makeCapturingLogger(subsystemLabel: "test.dynamicLevel", box: box)

            logger.debug("suppressed before the level is raised")
            #expect(logger.logLevel == .error)

            LogManager.setLevel(.debug, forSubsystemLabel: "test.dynamicLevel")
            #expect(logger.logLevel == .debug)
            logger.debug("passes after the level is raised")

            let entries = box.snapshot()
            #expect(entries.count == 1)
            #expect(entries.first?.message == "passes after the level is raised")
        }
    }

    /// A subsystem without its own override falls back to `defaultLevel`,
    /// and reflects a later change to it just as live as a per-subsystem
    /// override does.
    @Test
    func subsystemWithoutOverrideTracksDefaultLevelLive() throws {
        let fallbackLabel = "test.defaultFallback.\(UUID().uuidString)"
        withIsolatedDefaultLevel {
            LogManager.defaultLevel = .critical
            #expect(LogManager.level(for: fallbackLabel) == .critical)

            LogManager.defaultLevel = .trace
            #expect(LogManager.level(for: fallbackLabel) == .trace)
        }
    }

    /// A failure log line carries its dynamic values (topic, correlation id,
    /// error chain) as structured metadata, not interpolated into the
    /// message string -- the shape every production call site in
    /// `MQTTNIOClient`/`CommunicationManager` uses.
    @Test
    func failureLogCarriesStructuredMetadataNotJustMessageText() async throws {
        try await withIsolatedSubsystemLevel("test.metadata") {
            let box = CaptureBox()
            LogManager.setLevel(.warning, forSubsystemLabel: "test.metadata")
            let logger = makeCapturingLogger(subsystemLabel: "test.metadata", box: box)

            logger.warning("Error publishing", metadata: [
                "topic": .string("coaty/3/-/Advertise:Identity/source-id"),
                "correlationId": .string("11111111-1111-4111-8111-111111111111"),
                "error": .string("connection reset by peer"),
            ])

            let entry = try #require(box.snapshot().first)
            #expect(entry.metadata["topic"] == .string("coaty/3/-/Advertise:Identity/source-id"))
            #expect(entry.metadata["correlationId"] == .string("11111111-1111-4111-8111-111111111111"))
            #expect(entry.metadata["error"] == .string("connection reset by peer"))
            #expect(entry.message == "Error publishing")
        }
    }

    /// `AxolotyLogHandler.logLevel`'s getter reads `LevelStore` on every log
    /// call, from whatever thread emits it -- including a NIO event loop in
    /// `MQTTNIOClient`'s connect/publish/receive callbacks -- while
    /// `setLevel(_:for:)` writes from wherever the embedding app calls it.
    /// Races many concurrent reads against many concurrent writes on one
    /// label; `LevelStore`'s lock must make this safe rather than corrupting
    /// the underlying dictionary. Doesn't assert a specific outcome value
    /// (the race is over ordering, not correctness of a given read) -- the
    /// point is that this completes without crashing. Run under
    /// `swift test --sanitize=thread` to catch a regression back to
    /// unsynchronized access.
    @Test
    func concurrentLevelReadsAndWritesDoNotRace() async throws {
        try await withIsolatedSubsystemLevel("test.concurrency") {
            let levels: [Logging.Logger.Level] = [.trace, .debug, .info, .notice, .warning, .error, .critical]
            await withTaskGroup(of: Void.self) { group in
                for i in 0 ..< 500 {
                    group.addTask {
                        LogManager.setLevel(levels[i % levels.count], forSubsystemLabel: "test.concurrency")
                    }
                    group.addTask {
                        _ = LogManager.level(for: "test.concurrency")
                    }
                }
            }
        }
    }
}
