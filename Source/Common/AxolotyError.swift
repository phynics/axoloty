//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  AxolotyError.swift
//  Axoloty
//
//

import Foundation
import ErrorKit

/// The base error type for all Axoloty related errors.
public enum AxolotyError: Throwable {
    /// Invalid argument error.
    case InvalidArgument(String)

    /// Decoding of a Coaty object or event failed.
    case DecodingFailure(String)

    /// Invalid configuration option.
    case InvalidConfiguration(String)

    /// An error that occured during runtime.
    case RuntimeError(String)

    public var userFriendlyMessage: String {
        switch self {
        case .InvalidArgument(let message),
             .DecodingFailure(let message),
             .InvalidConfiguration(let message),
             .RuntimeError(let message):
            return message
        }
    }
}
