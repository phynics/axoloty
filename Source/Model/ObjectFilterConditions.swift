//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  ObjectFilterConditions.swift
//  Axoloty
//

/// Defines a set of conditions for filtering objects. Filter conditions can be
/// combined by logical AND or OR.
public class ObjectFilterConditions: Codable {

    // MARK: - Attributes.

    /// The set of (optional) filter conditions which are combined by logical AND.
    internal(set) public var and: [ObjectFilterCondition]?

    /// The set of (optional) filter conditions which are combined by logical OR.
    internal(set) public var or: [ObjectFilterCondition]?

    // MARK: - Initializers.

    private init(_ and: [ObjectFilterCondition]? = nil, _ or: [ObjectFilterCondition]? = nil) {
        self.and = and
        self.or = or
    }

    /// Create an instance of ObjectFilterConditions.
    ///
    /// An object filter condition is defined by the name of an object property
    /// and a filter expression. The filter expression must evaluate to true
    /// when applied to the property's value for the condition to become true.
    ///
    /// The object property to be applied for filtering is specified either in
    /// dot notation or array notation. In dot notation, the name of the object
    /// property is specified as a string (e.g. `"objectId"`). It may include
    /// dots (`.`) to access nested properties of subobjects (e.g.
    /// `"message.name"`). If a single property name contains dots itself, you
    /// obviously cannot use dot notation. Instead, specify the property or
    /// nested properties as an array of strings (e.g. `["property.with.dots",
    /// "subproperty.with.dots"]`).
    ///
    /// A filter expression consists of a filter operator and an
    /// operator-specific number of filter operands (at most two). You should
    /// use one of the typesafe `FilterOperations` functions to specify a filter
    /// expression.
    ///
    /// - Parameter and: Multiple filter conditions combined by logical AND.
    ///   Specify either the `and` or the `or` property, or none, but *never* both.
    public convenience init(and: [ObjectFilterCondition]) {
        self.init(and, nil)
    }

    /// Create an instance of ObjectFilterConditions.
    ///
    /// An object filter condition is defined by the name of an object property
    /// and a filter expression. The filter expression must evaluate to true
    /// when applied to the property's value for the condition to become true.
    ///
    /// The object property to be applied for filtering is specified either in
    /// dot notation or array notation. In dot notation, the name of the object
    /// property is specified as a string (e.g. `"objectId"`). It may include
    /// dots (`.`) to access nested properties of subobjects (e.g.
    /// `"message.name"`). If a single property name contains dots itself, you
    /// obviously cannot use dot notation. Instead, specify the property or
    /// nested properties as an array of strings (e.g. `["property.with.dots",
    /// "subproperty.with.dots"]`).
    ///
    /// A filter expression consists of a filter operator and an
    /// operator-specific number of filter operands (at most two). You should
    /// use one of the typesafe `FilterOperations` functions to specify a filter
    /// expression.
    ///
    /// - Parameter or: Multiple filter conditions combined by logical OR.
    ///   Specify either the `and` or the `or` property, or none, but *never* both.
    public convenience init(or: [ObjectFilterCondition]) {
        self.init(nil, or)
    }

    // MARK: - Codable methods.

    enum CodingKeys: String, CodingKey {
        case and
        case or
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if let andObjectFilterConditions = and {
            try container.encode(andObjectFilterConditions, forKey: .and)
        } else if let orObjectFilterConditions = or {
            try container.encode(orObjectFilterConditions, forKey: .or)
        }
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let hasAnd = container.contains(.and)
        let hasOr = container.contains(.or)
        guard hasAnd != hasOr else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ObjectFilterConditions must contain exactly one of 'and' or 'or'"
            ))
        }

        if hasAnd {
            and = try container.decode([ObjectFilterCondition].self, forKey: .and)
            or = nil
        } else {
            and = nil
            or = try container.decode([ObjectFilterCondition].self, forKey: .or)
        }
    }

    // MARK: - Builder methods.

    /// Builds a new `ObjectFilterConditions` object using the convenience closure syntax.
    /// Using this builder method the conditions will automatically be linked using logical AND.
    ///
    /// - NOTE: You may want to consider to use the usual initializer instead and construct
    ///   the array of `ObjectFilterCondition` objects using the dedicated single instance builder.
    /// - Parameter closure: the builder closure, preferably used as trailing closure.
    /// - Returns: `ObjectFilterConditions` configured using the builder.
    public static func buildAnd(_ closure: (ObjectFilterConditionsBuilder) throws -> Void) throws -> ObjectFilterConditions {
        let builder = ObjectFilterConditionsBuilder()
        try closure(builder)

        guard let and = builder.and else {
            throw AxolotyError.invalidArgument(argument: "and", reason: "ObjectFilterConditionsBuilder.and is nil")
        }

        return ObjectFilterConditions(and)
    }

    /// Builds a new `ObjectFilterConditions` object using the convenience closure syntax.
    /// Using this builder method the conditions will automatically be linked using logical OR.
    ///
    /// - NOTE: You may want to consider to use the usual initializer instead and construct
    ///   the array of `ObjectFilterCondition` objects using the dedicated single instance builder.
    /// - Parameter closure: the builder closure, preferably used as trailing closure.
    /// - Returns: `ObjectFilterConditions` configured using the builder.
    public static func buildOr(_ closure: (ObjectFilterConditionsBuilder) throws -> Void) throws -> ObjectFilterConditions {
        let builder = ObjectFilterConditionsBuilder()
        try closure(builder)

        guard let or = builder.or else {
            throw AxolotyError.invalidArgument(argument: "or", reason: "ObjectFilterConditionsBuilder.or is nil")
        }

        return ObjectFilterConditions(or)
    }
}
