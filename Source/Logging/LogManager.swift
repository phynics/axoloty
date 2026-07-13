//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  LogManager.swift
//  Axoloty
//
//

import Foundation
import Logging

/// Provides a global logger for the Axoloty framework. Its implementation is
/// based on [`swift-log`](https://github.com/apple/swift-log).
///
/// - Note: Axoloty is a library, not an application, so it deliberately does
///   **not** call `LoggingSystem.bootstrap(...)`. That call is global, may be
///   made at most once per process, and is reserved for the embedding
///   application to choose (and own) the logging backend. Absent an
///   application-provided bootstrap, `Logger` falls back to swift-log's
///   default `StreamLogHandler` (stdout/stderr) - which also happens to fix
///   the previous `AppleSystemLogDestination`-based implementation being
///   Apple-only and unusable on Linux.
class LogManager {

    nonisolated(unsafe) internal static var logLevel = Logging.Logger.Level.error

    /// Computed once, on first access, using whatever `logLevel` has been set
    /// to at that point (see `Container.resolve(components:configuration:)`,
    /// which sets `logLevel` from the agent's `Configuration` before
    /// resolving any component that might touch this logger for the first
    /// time). This mirrors the original XCGLogger-based implementation
    /// exactly: it is a known, pre-existing limitation - not something
    /// introduced by this swap - that a `logLevel` change made *after* `log`
    /// has already been computed once in the process has no further effect.
    nonisolated(unsafe) internal static var log: Logging.Logger = {
        var log = Logging.Logger(label: "Axoloty")
        log.logLevel = LogManager.logLevel
        return log
    }()

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
