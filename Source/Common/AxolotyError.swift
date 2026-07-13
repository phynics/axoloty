//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  AxolotyError.swift
//  Axoloty
//
//

import Foundation

/// The base error type for all Axoloty related errors.
public enum AxolotyError: Error {
    
    /// Invalid argument error.
    case InvalidArgument(String)
    
    /// Decoding of a Coaty object or event failed.
    case DecodingFailure(String)
    
    /// Invalid configuration option.
    case InvalidConfiguration(String)
    
    /// An error that occured during runtime.
    case RuntimeError(String)
}
