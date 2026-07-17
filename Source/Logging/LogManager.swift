//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  LogManager.swift
//  Axoloty
//
//

import Foundation
import Logging

/// Vends per-subsystem loggers for the Axoloty framework, backed by
/// [`swift-log`](https://github.com/apple/swift-log).
///
/// - Note: Axoloty is a library, not an application, so it deliberately does
///   **not** call `LoggingSystem.bootstrap(...)`. That call is global, may be
///   made at most once per process, and is reserved for the embedding
///   application.
/// - Note: Each `LogManager.logger(_:)`-vended `Logger` is backed by
///   `AxolotyLogHandler`, not the app's `LoggingSystem`-bootstrapped
///   handler. swift-log exposes no public API to retrieve "the currently
///   bootstrapped handler" after the fact, and every call site in this
///   codebase holds its logger in a stored property (`private let log = ...`)
///   set once at `init`. A `Logger.logLevel` baked in at that vend time --
///   which is what `Logger(label:)` implies -- can never reflect a later
///   `LogManager.setLevel(_:for:)` call for a `Logger` a call site already
///   holds. Proxying `logLevel` through a handler that reads a live,
///   subsystem-keyed store is the only way to make a level change observable
///   without every call site re-vending its logger on every use.
public enum LogManager {

    private static let store = LevelStore()

    /// The level applied to any subsystem without its own override via
    /// `setLevel(_:for:)`.
    public static var defaultLevel: Logging.Logger.Level {
        get { store.defaultLevel }
        set { store.defaultLevel = newValue }
    }

    /// Returns a logger for the given subsystem.
    ///
    /// Safe to call once and store in a `private let`, or to call fresh at
    /// each log site -- a level change made after the `Logger` is vended
    /// still takes effect, since `logLevel` is read live from
    /// `AxolotyLogHandler` on every log call.
    public static func logger(_ subsystem: Subsystem) -> Logging.Logger {
        Logging.Logger(label: "Axoloty.\(subsystem.rawValue)") { _ in
            AxolotyLogHandler(subsystem: subsystem.rawValue)
        }
    }

    /// Sets the log level for a specific subsystem, or -- when `subsystem` is
    /// `nil` -- `defaultLevel`, applied to every subsystem without its own
    /// override. Takes effect immediately for every already-vended `Logger`.
    ///
    /// - Note: This is process-wide, not instance-local: every `Logger` for
    ///   `subsystem` (or, with `subsystem: nil`, every `Logger` without its
    ///   own override) observes the change, including ones already vended
    ///   and stored elsewhere. `AxolotyLogHandler.logLevel`'s setter routes
    ///   here too, so assigning to a single `Logger`'s `.logLevel` has this
    ///   same global effect for its subsystem -- swift-log clients that
    ///   expect `logger.logLevel = x` to be instance-local should use
    ///   `setLevel(_:for:)` explicitly instead, for clarity at the call site.
    public static func setLevel(_ level: Logging.Logger.Level, for subsystem: Subsystem? = nil) {
        store.setLevel(level, forSubsystemLabel: subsystem?.rawValue)
    }

    /// Returns the effective level for a subsystem label, falling back to
    /// `defaultLevel` when no override has been set. Takes a raw label
    /// (rather than `Subsystem`) so `AxolotyLogHandler` can look up its own
    /// level without round-tripping through `Subsystem(rawValue:)`.
    ///
    /// - Note: Called on every log call, from whatever thread emits it (e.g.
    ///   a NIO event loop) -- see `LevelStore`.
    static func level(for subsystemLabel: String) -> Logging.Logger.Level {
        store.level(for: subsystemLabel)
    }

    /// Sets the level for a subsystem by its raw label. Internal counterpart
    /// to `setLevel(_:for:)` used by `AxolotyLogHandler`'s `logLevel`
    /// setter, which only has the label, not the `Subsystem` case.
    static func setLevel(_ level: Logging.Logger.Level, forSubsystemLabel subsystemLabel: String) {
        store.setLevel(level, forSubsystemLabel: subsystemLabel)
    }

    /// Maps the public, Configuration-facing `AxolotyLogLevel` to a
    /// `swift-log` level.
    static internal func getLogLevel(logLevel: AxolotyLogLevel) -> Logging.Logger.Level {
        switch logLevel {
        case .debug:
            return .debug
        case .error:
            return .error
        case .info:
            return .info
        case .warning:
            return .warning
        }
    }
}

/// Lock-guarded storage for `LogManager`'s subsystem levels.
///
/// `AxolotyLogHandler.logLevel`'s getter reads this on every single log call
/// -- including from arbitrary threads such as a NIO event loop in
/// `MQTTNIOClient`'s connect/publish/receive callbacks -- while
/// `LogManager.setLevel(_:for:)` writes to it from wherever the embedding
/// app calls it. Concurrent unsynchronized access to a Swift `Dictionary` is
/// undefined behavior, not just a stale read, so this needs real
/// synchronization rather than the `nonisolated(unsafe)` a write-once-then-
/// read-only global would get away with.
private final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var subsystemLevels: [String: Logging.Logger.Level] = [:]
    private var _defaultLevel: Logging.Logger.Level = .error

    var defaultLevel: Logging.Logger.Level {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _defaultLevel
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _defaultLevel = newValue
        }
    }

    func level(for subsystemLabel: String) -> Logging.Logger.Level {
        lock.lock()
        defer { lock.unlock() }
        return subsystemLevels[subsystemLabel] ?? _defaultLevel
    }

    /// Sets `defaultLevel` when `subsystemLabel` is `nil`, or the level for
    /// that specific subsystem label otherwise.
    func setLevel(_ level: Logging.Logger.Level, forSubsystemLabel subsystemLabel: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let subsystemLabel else {
            _defaultLevel = level
            return
        }
        subsystemLevels[subsystemLabel] = level
    }
}

/// `LogHandler` backing every `LogManager.logger(_:)`-vended `Logger`.
///
/// Delegates actual output to `StreamLogHandler`, but overrides `logLevel` to
/// read/write through `LogManager`'s subsystem-keyed level store instead of
/// the fixed value `StreamLogHandler` would otherwise bake in at construction
/// time. See ``LogManager``'s doc comment for why this indirection exists.
struct AxolotyLogHandler: LogHandler {
    let subsystem: String
    private var backing: StreamLogHandler

    init(subsystem: String) {
        self.subsystem = subsystem
        self.backing = StreamLogHandler.standardError(label: "Axoloty.\(subsystem)")
    }

    var metadataProvider: Logging.Logger.MetadataProvider? {
        get { backing.metadataProvider }
        set { backing.metadataProvider = newValue }
    }

    var metadata: Logging.Logger.Metadata {
        get { backing.metadata }
        set { backing.metadata = newValue }
    }

    var logLevel: Logging.Logger.Level {
        get { LogManager.level(for: subsystem) }
        set { LogManager.setLevel(newValue, forSubsystemLabel: subsystem) }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { backing[metadataKey: key] }
        set { backing[metadataKey: key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        backing.log(event: event)
    }
}

/// Subsystem labels used to scope `LogManager.logger(_:)` output
/// (`Axoloty.<subsystem>`) and level overrides
/// (`LogManager.setLevel(_:for:)`).
public enum Subsystem: String, Sendable {
    /// Communication manager, event publish/subscribe, and topic handling.
    case communication

    /// IO routing: association rules, source/actor matching.
    case ioRouting

    /// Container/controller lifecycle and bootstrap.
    case runtime

    /// SensorThings sensor registration and observation publication.
    case sensorThings

    /// The MQTT transport client and broker discovery.
    case mqtt
}

/// The `AxolotyLogLevel` enum defines the verbositiy of the internal Axoloty logger.
public enum AxolotyLogLevel {

    /// Logs information about underlying MQTT topic subscriptions (e.g. subscribe() and unsubscribe() operations)
    /// and OperatingState of communication manager.
    case debug

    /// Logs events such as CommunicationState of communication manager.
    case info

    /// Logs warnings that indicate partial failures which may indicate larger issues.
    case warning

    /// Logs fatal errors such as decoding failures.
    case error
}
