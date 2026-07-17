//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  AxolotyError.swift
//  Axoloty
//
//

import ErrorKit
import Foundation

/// The base error type for all Axoloty related errors.
public enum AxolotyError: Throwable, Catching {
    /// An argument passed to an Axoloty API was invalid.
    case invalidArgument(argument: String, reason: String)

    /// Decoding of a Coaty object or event failed.
    case decodingFailure(type: String, reason: String, payload: String? = nil)

    /// A configuration option was missing or invalid.
    case invalidConfiguration(option: String, reason: String)

    /// An error that occurred during runtime, classified by ``RuntimeErrorCode``.
    case runtime(code: RuntimeErrorCode, reason: String)

    /// A foreign error caught at an Axoloty API boundary and wrapped so it
    /// never escapes as a bare `Error`. Created by `AxolotyError.caught(_:)`
    /// or `AxolotyError.catch { ... }` from ErrorKit's ``Catching``.
    case caught(Error)

    /// A stable, machine-readable classification for ``runtime(code:reason:)``.
    ///
    /// - Note: `AxolotyError` is public API; downstream code may switch on
    ///   this code, so treat it as a semver surface -- add new cases rather
    ///   than repurposing or removing existing ones.
    public enum RuntimeErrorCode: String, Sendable, CaseIterable {
        /// A required component (client, manager, coordinator) was used
        /// before being started.
        case notStarted
        /// A wait for a runtime condition exceeded its deadline.
        case timedOut
        /// An event or state stream ended before delivering an expected value.
        case streamEnded
        /// No broker could be reached or discovered.
        case brokerUnavailable
        /// A topic subscription request was rejected by the transport.
        case subscriptionFailed
        /// A publish request was rejected by the transport.
        case publishFailed
        /// An IO route could not be resolved to an associated source/actor.
        case ioRouteUnresolved
        /// A referenced entity (e.g. a sensor) was not registered.
        case notRegistered
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidArgument(argument, reason):
            return "\(argument): \(reason)"
        case let .decodingFailure(type, reason, _):
            return "\(type): \(reason)"
        case let .invalidConfiguration(option, reason):
            return "\(option): \(reason)"
        case let .runtime(_, reason):
            return reason
        case let .caught(error):
            return ErrorKit.userFriendlyMessage(for: error)
        }
    }
}
