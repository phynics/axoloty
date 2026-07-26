//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CallEvent.swift
//  Axoloty
//

import Foundation
import AxolotyWire

/// Defines criteria for filtering Coaty objects. Used in combination with Call
/// events, and with the `ObjectMatcher` functionality.
public typealias ContextFilter = ObjectFilter

/// Defines a filter condition for filtering Coaty objects. Used in combination
/// with Call events, and with the `ObjectMatcher` functionality.
public typealias ContextFilterCondition = ObjectFilterCondition

/// CallEvent provides a generic implementation for invoking remote operations.
public class CallEvent: CommunicationEvent<CallEventData> {
    
    // MARK: - Internal attributes.
    
    internal var operation: String?

    // MARK: - Static Factory Methods.

    /// Create a CallEvent instance for invoking a remote operation call with the given
    /// operation name, parameters (optional), and a context filter (optional).
    ///
    /// Parameters must be supplied as raw JSON text — either a JSON object
    /// (by-name parameters) or a JSON array (by-position parameters).
    /// If a context filter is specified, the given remote call is only executed if
    /// the filter conditions match a context object provided by the remote end.
    ///
    /// - Parameters:
    ///     - operation: a non-empty string containing the name of the operation to be invoked
    ///     - parameters: raw JSON text holding the parameter values to be used
    ///       during the invocation of the operation (optional)
    ///     - filter: a context filter that must match a given context object at the remote
    ///       end (optional)
    /// - Returns: a Call event with the given parameters
    /// - Throws: if operation name is invalid
    public static func with(operation: String, parameters: String?, filter: ContextFilter? = nil) throws -> CallEvent {
        let callEventdata = CallEventData.createFrom(parameters: parameters, filter: filter)
        return try .init(eventType: .call, eventData: callEventdata, operation: operation)
    }

    // MARK: - Initializers.

    fileprivate override init(eventType: WireEventType, eventData: CallEventData) {
        super.init(eventType: eventType, eventData: eventData)
    }
    
    fileprivate init(eventType: WireEventType, eventData: CallEventData, operation: String) throws {
        guard TopicBuilder.isValidEventTypeFilter(filter: operation) else {
            throw AxolotyError.invalidArgument(argument: "operation", reason: "\"\(operation)\" is not a valid call operation")
        }
        
        super.init(eventType: eventType, eventData: eventData)
        self.typeFilter = operation
        self.operation = operation
    }
    
    // MARK: - Codable methods.
    
    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

/// CallEventData provides the entire message payload data for a `CallEvent`.
public class CallEventData: CommunicationEventData {
    
    // MARK: - Public attributes.
    
    /// The operation parameters as raw JSON text. May be a JSON object
    /// (by-name parameters) or a JSON array (by-position parameters).
    public var parameters: String?
    
    /// Defines conditions that must match a context object
    /// provided by the remote end in order to allow execution of the remote operation.
    public var filter: ContextFilter?
    
    // MARK: - Initializers.
    
    private init(_ parameters: String? = nil, _ filter: ContextFilter? = nil) {
        super.init()
        self.parameters = parameters
        self.filter = filter
    }
    
    // MARK: - Factory methods.
    
    internal static func createFrom(parameters: String?, filter: ContextFilter? = nil) -> CallEventData {
        return .init(parameters, filter)
    }
    
    // MARK: - Access methods.
    
    /// Returns the raw JSON text of the keyword parameter with the given name.
    /// Returns `nil` if the given name is missing, if parameters are not a JSON
    /// object, or if no parameters have been specified.
    ///
    /// - Parameter name: The parameter name to look up.
    /// - Returns: The raw JSON text of the parameter value, or `nil`.
    public func getParameterByName(name: String) -> String? {
        guard let parameters,
              let data = parameters.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: RawJSONValue].self, from: data) else {
            return nil
        }
        guard let value = object[name] else { return nil }
        guard let encoded = try? JSONEncoder().encode(value) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
    
    /// Returns the raw JSON text of the positional parameter at the given index.
    /// Returns `nil` if the given index is out of range, if parameters are not
    /// a JSON array, or if no parameters have been specified.
    ///
    /// - Parameter index: The zero-based parameter index.
    /// - Returns: The raw JSON text of the parameter value, or `nil`.
    public func getParameterByIndex(index: Int) -> String? {
        guard let parameters,
              let data = parameters.data(using: .utf8),
              let array = try? JSONDecoder().decode([RawJSONValue].self, from: data) else {
            return nil
        }
        guard index >= 0, index < array.count else { return nil }
        guard let encoded = try? JSONEncoder().encode(array[index]) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    // MARK: - Codable methods.
    
    enum CodingKeys: String, CodingKey {
        case parameters
        case filter
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.parameters = try RawJSONValue.decodeRawStringIfPresent(from: container, forKey: .parameters)
        self.filter = try container.decodeIfPresent(ContextFilter.self, forKey: .filter)
        
        try super.init(from: decoder)
    }
    
    override public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.filter, forKey: .filter)
        try RawJSONValue.encodeRawStringIfPresent(self.parameters, to: &container, forKey: .parameters)
    }

}
