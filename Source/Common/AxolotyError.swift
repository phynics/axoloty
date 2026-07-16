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
    /// Invalid argument error.
    case InvalidArgument(String)

    /// Decoding of a Coaty object or event failed.
    case DecodingFailure(String)

    /// Invalid configuration option.
    case InvalidConfiguration(String)

    /// An error that occured during runtime.
    case RuntimeError(String)

    /// A foreign error caught at an Axoloty API boundary and wrapped so it
    /// never escapes as a bare `Error`. Created by `AxolotyError.caught(_:)`
    /// or `AxolotyError.catch { ... }` from ErrorKit's ``Catching``.
    case caught(Error)

    public var userFriendlyMessage: String {
        switch self {
        case let .InvalidArgument(message),
             let .DecodingFailure(message),
             let .InvalidConfiguration(message),
             let .RuntimeError(message):
            return message
        case let .caught(error):
            return ErrorKit.userFriendlyMessage(for: error)
        }
    }
}
