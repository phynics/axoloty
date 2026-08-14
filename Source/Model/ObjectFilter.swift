//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  ObjectFilter.swift
//  Axoloty
//

import Foundation

/// Defines criteria for filtering and ordering a result
/// set of Coaty objects. Used in combination with Query events
/// and database operations, as well as the `ObjectMatcher` functionality.
public class ObjectFilter: Codable {

    // MARK: - Attributes.
    
    /// A set of conditions for filtering objects (optional).
    public var conditions: ObjectFilterConditions?
    
    /// A single condition for filtering objects (optional).
    public var condition: ObjectFilterCondition?
    
    /// Determines the ordering of result objects by an array of
    /// `OrderByProperty` objects.
    public var orderByProperties: [OrderByProperty]?
    
    /// If a take count is given, no more than that many objects will be returned
    /// (but possibly less, if the request itself yields less objects).
    /// Typically, this option is only useful if the `orderByProperties` option
    /// is also specified to ensure consistent ordering of paginated results.
    public var take: Int?
    
    /// If skip count is given that many objects are skipped before beginning to
    /// return result objects.
    /// Typically, this option is only useful if the `orderByProperties` option
    /// is also specified to ensure consistent ordering of paginated results.
    public var skip: Int?
    
    private init(_ conditions: ObjectFilterConditions? = nil, _ condition: ObjectFilterCondition? = nil, _ orderByProperties: [OrderByProperty]? = nil, _ take: Int? = nil, _ skip: Int? = nil) {
        self.conditions = conditions
        self.condition = condition
        self.orderByProperties = orderByProperties
        self.take = take
        self.skip = skip
    }

    // MARK: - Initializers.
    
    /// Create an instance of ObjectFilter based on a single condition.
    /// - Parameters:
    ///     - condition: A single condition for filtering objects.
    ///     - orderByProperties: Determines the ordering of result objects.
    ///     - take: take at most the given count of hits
    ///     - skip: skip the given count of hits
    public convenience init(condition: ObjectFilterCondition, orderByProperties: [OrderByProperty]? = nil, take: Int? = nil, skip: Int? = nil) {
        self.init(nil, condition, orderByProperties, take, skip)
    }
    
    /// Create an instance of ObjectFilter based on a set of conditions.
    /// - Parameters:
    ///     - condition: A single condition for filtering objects.
    ///     - orderByProperties: Determines the ordering of result objects.
    ///     - take: take at most the given count of hits
    ///     - skip: skip the given count of hits
    public convenience init(conditions: ObjectFilterConditions, orderByProperties: [OrderByProperty]? = nil, take: Int? = nil, skip: Int? = nil) {
        self.init(conditions, nil, orderByProperties, take, skip)
    }

    /// Creates an empty object filter (no conditions, ordering, or paging)
    /// that encodes to `{}`. Used to emit the Coaty wire format's
    /// `objectFilter` field on Query events even when no filtering is desired:
    /// CoatyJS consumers validate incoming Query events with
    /// `isObjectFilterValid`, which rejects a Query whose `objectFilter` is
    /// absent (the field is treated as required on the wire).
    public convenience init() {
        self.init(nil, nil, nil, nil, nil)
    }

    // MARK: - Codable methods.
    
    enum CodingKeys: String, CodingKey {
        case conditions
        case orderByProperties
        case take
        case skip
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        if let condition = condition {
            try container.encodeIfPresent(condition, forKey: .conditions)
        } else if let conditions = conditions {
            try container.encodeIfPresent(conditions, forKey: .conditions)
        }
        
        try container.encodeIfPresent(orderByProperties, forKey: .orderByProperties)
        try container.encodeIfPresent(take, forKey: .take)
        try container.encodeIfPresent(skip, forKey: .skip)
    }
    
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if container.contains(.conditions) {
            if try container.decodeNil(forKey: .conditions) {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath + [CodingKeys.conditions],
                    debugDescription: "ObjectFilter.conditions cannot be null"
                ))
            } else {
                do {
                    condition = try container.decode(ObjectFilterCondition.self, forKey: .conditions)
                    conditions = nil
                } catch {
                    do {
                        conditions = try container.decode(ObjectFilterConditions.self, forKey: .conditions)
                        condition = nil
                    } catch {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: decoder.codingPath + [CodingKeys.conditions],
                            debugDescription: "ObjectFilter.conditions is neither a valid condition nor condition set"
                        ))
                    }
                }
            }
        } else {
            condition = nil
            conditions = nil
        }
        
        take = try container.decodeIfPresent(Int.self, forKey: .take)
        skip = try container.decodeIfPresent(Int.self, forKey: .skip)
        orderByProperties = try container.decodeIfPresent([OrderByProperty].self, forKey: .orderByProperties)
    }
    
    // MARK: - Builder methods.
    
    /// Builds a new `ObjectFilter` using the convenience closure syntax. This method can only be
    /// used to build objects that have exactly _one_ condition.
    ///
    /// - Parameter closure: the builder closure, preferably used as trailing closure.
    /// - Returns: ObjectFilter configured using the builder.
    public static func buildWithCondition(_ closure: (ObjectFilterBuilder) throws -> Void) throws -> ObjectFilter {
        let builder = ObjectFilterBuilder()
        try closure(builder)
        
        guard let condition = builder.condition else {
            throw AxolotyError.invalidArgument(argument: "condition", reason: "condition is not set")
        }
        
        return ObjectFilter(condition: condition, orderByProperties: builder.orderByProperties, take: builder.take, skip: builder.skip)
    }
    
    /// Builds a new `ObjectFilter` using the convenience closure syntax. This method can only be
    /// used to build objects that have _multiple_ conditions.
    ///
    /// - Parameter closure: the builder closure, preferably used as trailing closure.
    /// - Returns: ObjectFilter configured using the builder.
    public static func buildWithConditions(_ closure: (ObjectFilterBuilder) throws -> Void) throws -> ObjectFilter {
        let builder = ObjectFilterBuilder()
        try closure(builder)
        
        guard let conditions = builder.conditions else {
            throw AxolotyError.invalidArgument(argument: "conditions", reason: "conditions are not set")
        }
        
        return ObjectFilter(conditions: conditions, orderByProperties: builder.orderByProperties, take: builder.take, skip: builder.skip)
    }
}

/// Determines the ordering of result objects by an array of (property name,
/// sort order) tuples. The results are ordered by the first tuple, then
/// by the second tuple, etc.
public class OrderByProperty: Codable {
    
    /// The ordered collection of filter properties.
    internal(set) public var objectFilterProperties: ObjectFilterProperty

    /// The sorting order.
    internal(set) public var sortingOrder: SortingOrder
    
    /// Create an OrderByProperty instance.
    /// - Parameters:
    ///     - properties: The object property used for ordering can be specified either in dot
    ///       notation or array notation. In dot notation, the name of the object
    ///       property is specified as a string (e.g. `"objectId"`). It may include
    ///       dots (`.`) to access nested properties of subobjects (e.g.
    ///       `"message.name"`). If a single property name contains dots itself, you
    ///       obviously cannot use dot notation. Instead, specify the property or
    ///       nested properties as an array of strings (e.g. `["property.with.dots",
    ///       "subproperty.with.dots"]`).
    ///     -sortingOrder: Ascending or descending sort order.
    public init(properties: ObjectFilterProperty, sortingOrder: SortingOrder) {
        self.objectFilterProperties = properties
        self.sortingOrder = sortingOrder
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(objectFilterProperties)
        try container.encode(sortingOrder.rawValue)
    }
    
    public required init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        objectFilterProperties = try container.decode(ObjectFilterProperty.self)
        let sortingOrderString = try container.decode(String.self)
        guard let decodedSortingOrder = SortingOrder(rawValue: sortingOrderString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(sortingOrderString)\" is not a valid SortingOrder"
            )
        }
        sortingOrder = decodedSortingOrder
    }
    
}

/// Defines the format of nested properties used in ObjectFilter `conditions`
/// and `orderByProperties` clauses. Both dot notation
/// (`"property.subproperty.subsubproperty"`) and array notation (`["property",
/// "subproperty", "subsubproperty"]`) are supported for naming nested
/// properties. Note that dot notation cannot be used if one of the properties
/// contains a dot (.) in its name. In such cases, array notation must be used.
public class ObjectFilterProperty: Codable {

    /// The name of a single filter property.
    internal(set) public var objectFilterProperty: String?

    /// The ordered collection of names of chained filter properties.
    internal(set) public var objectFilterProperties: [String]?
    
    private init(objectFilterProperty: String? = nil, objectFilterProperties: [String]? = nil) {
        self.objectFilterProperty = objectFilterProperty
        self.objectFilterProperties = objectFilterProperties
    }
    
    /// Create an instance of ObjectFilterProperty.
    /// - Parameter objectFilterProperty: Specifies filter property in dot notation
    ///   (`"property.subproperty.subsubproperty"`). Note that dot notation cannot
    ///   be used if one of the properties contains a dot (.) in its name. In such
    ///   cases, array notation (see `objectFilterProperties`) must be used.
    public convenience init(_ objectFilterProperty: String) {
        self.init(objectFilterProperty: objectFilterProperty, objectFilterProperties: nil)
    }
    
    /// Create an instance of ObjectFilterProperty.
    /// - Parameter objectFilterProperties: Specifies filter property in 
    ///   array notation (`["property", "subproperty", "subsubproperty"]`).
    public convenience init(_ objectFilterProperties: [String]) {
        self.init(objectFilterProperty: nil, objectFilterProperties: objectFilterProperties)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let objectFilterProperty = objectFilterProperty {
            try container.encode(objectFilterProperty)
        } else if let objectFilterProperties = objectFilterProperties {
            try container.encode(objectFilterProperties)
        }
    }
    
    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let objectFilterProperty = try? container.decode(String.self) {
            let pathComponents = objectFilterProperty.split(separator: ".", omittingEmptySubsequences: false)
            guard !objectFilterProperty.isEmpty, pathComponents.allSatisfy({ !$0.isEmpty }) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "ObjectFilterProperty cannot contain empty path components"
                )
            }
            self.objectFilterProperty = objectFilterProperty
        } else if let objectFilterProperties = try? container.decode([String].self) {
            guard !objectFilterProperties.isEmpty,
                  objectFilterProperties.allSatisfy({ !$0.isEmpty }) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "ObjectFilterProperty cannot contain empty path components"
                )
            }
            self.objectFilterProperties = objectFilterProperties
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObjectFilterProperty must be a string or string array"
            )
        }
    }
}

/// Defines the sort order for an OrderbyProperty.
public enum SortingOrder: String {

    /// Ascending ordering.
    case Asc

    /// Descending ordering.
    case Desc
}

 /// An object filter condition is defined by an object property name - object
 /// filter expression pair. The filter expression must evaluate to true when
 /// applied to the object property's value for the condition to become true.
public class ObjectFilterCondition: Codable {

    // MARK: - Attributes.
    
    /// The filter property of this filter condition.
    internal(set) public var property: ObjectFilterProperty

    /// The filter expression of this filter condition.
    internal(set) public var expression: ObjectFilterExpression
    
    // MARK: - Initializers.
    
    /// Creates an instance of ObjectFilterCondition.
    /// - Parameters:
    ///     - property: Defines the format of nested properties used in an ObjectFilterCondition.
    ///     - expression: A filter expression consists of a filter operator and an
    ///       operator-specific number of filter operands (at most two).
    public init(property: ObjectFilterProperty, expression: ObjectFilterExpression) {
        self.property = property
        self.expression = expression
    }
    
    // MARK: - Codable methods.
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(property)
        try container.encode(expression)
    }
    
    public required init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()

        self.property = try container.decode(ObjectFilterProperty.self)
        self.expression = try container.decode(ObjectFilterExpression.self)

        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObjectFilterCondition must contain exactly a property and expression"
            )
        }
     }
    
    // MARK: - Builder methods.
    
    /// Builds a new `ObjectFilterCondition` using the convenience closure syntax.
    ///
    /// - Parameter closure: the builder closure, preferably used as trailing closure.
    /// - Returns: ObjectFilterCondition configured using the builder.
    public static func build(_ closure: (ObjectFilterConditionBuilder) throws -> Void) throws -> ObjectFilterCondition {
        let builder = ObjectFilterConditionBuilder()
        try closure(builder)
        
        guard let expression = builder.expression, let property = builder.property else {
            throw AxolotyError.invalidArgument(argument: "property/expression", reason: "the object filter condition could not be built")
        }
        
        return ObjectFilterCondition(property: property, expression: expression)
    }
}

// MARK: - Builder objects.

/// Convenience builder class for `ObjectFilter` objects.
public class ObjectFilterBuilder {
    public var conditions: ObjectFilterConditions?
    public var condition: ObjectFilterCondition?
    public var orderByProperties: [OrderByProperty]?
    public var take: Int?
    public var skip: Int?
}

/// Convenience builder class for `ObjectFilterCondition` objects.
public class ObjectFilterConditionBuilder {
    public var property: ObjectFilterProperty?
    public var expression: ObjectFilterExpression?
}

/// Convenience builder class for `ObjectFilterConditions` objects.
///
/// - NOTE: You may want to consider to use the usual initializer instead and construct
///   the array of `ObjectFilterCondition` objects using the dedicated single instance builder.
public class ObjectFilterConditionsBuilder {
    public var and: [ObjectFilterCondition]?
    public var or: [ObjectFilterCondition]?
}
