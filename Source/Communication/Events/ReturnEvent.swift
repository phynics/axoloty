//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  ReturnEvent.swift
//  Axoloty
//

import Foundation

/// ReturnEvent provides a generic implementation for responding to a
/// `CallEvent`.
public class ReturnEvent: CommunicationEvent<ReturnEventData> {

    // MARK: - Static Factory Methods.

    /// Create a ReturnEvent instance for a remote operation call that
    /// successfully yields a result.
    ///
    /// - Parameters:
    ///   - result: the result value to be returned as raw JSON text (any
    ///     JSON data type)
    ///   - executionInfo: information about the execution of the operation
    ///     as raw JSON text (optional)
    /// - Returns: a Return event with the given parameters
    public static func with(result: String, executionInfo: String?) -> ReturnEvent {
        let returnEventData = ReturnEventData.createFrom(result: result, executionInfo: executionInfo, error: nil)
        return .init(eventType: .Return, eventData: returnEventData)
    }
    
    /// Create a ReturnEvent instance for a remote operation call that yields an
    /// error.
    ///
    /// The error code given is an integer that indicates the error type that
    /// occurred, either a predefined error or an application defined one.
    /// Predefined error codes are defined by the `RemoteCallErrorCode` enum.
    /// Predefined error codes are within the range -32768 to -32000.
    /// Application defined error codes must be defined outside this range.
    ///
    /// The error message provides a short description of the error. Predefined
    /// error messages exist for all predefined error codes (see enum
    /// `RemoteCallErrorMessage`).
    ///
    /// - Parameters:
    ///   - error: The error including the code that indicates the error type
    ///            and the message string providing a short description of the
    ///            error.
    ///   - executionInfo: information about the execution of the operation
    ///     as raw JSON text (optional)
    /// - Returns: a Return event with the given parameters
    public static func with(error: ReturnError, executionInfo: String?) -> ReturnEvent {
        let returnEventData = ReturnEventData.createFrom(result: nil, executionInfo: executionInfo, error: error)
        return .init(eventType: .Return, eventData: returnEventData)
    }
    
    // MARK: - Initializers.

    fileprivate override init(eventType: CommunicationEventType, eventData: ReturnEventData) {
        super.init(eventType: eventType, eventData: eventData)
    }

    // MARK: - Codable methods.
    
    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
    
}

public class ReturnEventData: CommunicationEventData {
    
    // MARK: - Public attributes.
    
    /// The result value to be returned (any JSON data type), stored as raw
    /// JSON text. The value is `nil` if operation execution yielded an error.
    public var result: String?

    /// Defines additional information about the execution environment (any
    /// JSON value) such as the execution time of the operation or the ID of
    /// the operated control unit (optional), stored as raw JSON text.
    public var executionInfo: String?
    
    /// The error object to be returned in case the operation call yielded an error (optional).
    /// The value is `nil` if the operation executed successfully.
    ///
    /// The error object consists of two properties: `code`, `message`.
    ///
    /// The error code given is an integer that indicates the error type
    /// that occurred, either a predefined error or an application defined one. Predefined error
    /// codes are defined by the `RemoteCallErrorCode` enum. Predefined error
    /// codes are within the range -32768 to -32000. Application defined error codes must be
    /// defined outside this range.
    ///
    /// The error message provides a short description of the error. Predefined error messages
    /// exist for all predefined error codes (see enum `RemoteCallErrorMessage`).
    public var error: ReturnError?
    
    // MARK: - Initializers.
    
    private init(result: String?, executionInfo: String?, error: ReturnError?) {
        self.result = result
        self.executionInfo = executionInfo
        self.error = error
        super.init()
    }
    
    // MARK: - Factory methods.
    
    internal static func createFrom(result: String?, executionInfo: String?, error: ReturnError?) -> ReturnEventData {
        
        return .init(result: result, executionInfo: executionInfo, error: error)
    }
    
    // MARK: - Codable methods.
    
    enum CodingKeys: String, CodingKey {
        case error
        case result
        case executionInfo
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executionInfo = try RawJSONValue.decodeRawStringIfPresent(from: container, forKey: .executionInfo)
        self.result = try RawJSONValue.decodeRawStringIfPresent(from: container, forKey: .result)
        self.error = try container.decodeIfPresent(ReturnError.self, forKey: .error)
        try super.init(from: decoder)
    }
    
    override public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try RawJSONValue.encodeRawStringIfPresent(self.executionInfo, to: &container, forKey: .executionInfo)
        try RawJSONValue.encodeRawStringIfPresent(self.result, to: &container, forKey: .result)
        try container.encodeIfPresent(self.error, forKey: .error)
    }
}

// MARK: - ReturnEvent internal classes.

/// Defines error codes for pre-defined remote call errors.
///
/// The integer error codes from and including -32768 to -32000 are reserved for pre-defined errors
/// encountered while executing a remote call. Any code within this range, but not defined explicitly
/// below is reserved for future use. The remaining integers are available for application defined errors.
///
/// The predefined error messages corresponding to these predefined error codes are defined by enum
/// `RemoteCallErrorMessage`.
public enum RemoteCallErrorCode: Int {
    case invalidParameters = -32602
}

/// Defines error messages for pre-defined remote call errors.
///
/// The predefined error codes corresponding to these predefined error messages are defined by enum
/// `RemoteCallErrorCode`.
public enum RemoteCallErrorMessage: String {
    case invalidParameters = "Invalid params"
}

public class ReturnError: Codable {
    
    public var code: Int
    public var message: String
    
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    
    public init(code: RemoteCallErrorCode = .invalidParameters, message: RemoteCallErrorMessage = .invalidParameters) {
        self.code = RemoteCallErrorCode.invalidParameters.rawValue
        self.message = RemoteCallErrorMessage.invalidParameters.rawValue
    }
    
    enum CodingKeys: String, CodingKey {
        case code
        case message
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(Int.self, forKey: .code)
        self.message = try container.decode( String.self, forKey: .message )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.code, forKey: .code)
        try container.encodeIfPresent(self.message, forKey: .message)
    }
    
}
