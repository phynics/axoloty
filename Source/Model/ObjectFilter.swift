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
        
        // The wire `conditions` field is either a single condition or a
        // conditions set (`and`/`or`); probe both shapes and keep whichever
        // decodes. A failure here means "not this shape", not a swallowed
        // error -- the other probe (or both failing, leaving both nil) is
        // the expected outcome for the non-matching shape.
        do {
            condition = try container.decodeIfPresent(ObjectFilterCondition.self, forKey: .conditions)
        } catch { /* Not this shape; try the other. */ }

        do {
            conditions = try container.decodeIfPresent(ObjectFilterConditions.self, forKey: .conditions)
         } catch { /* Not this shape; the other probe above already ran. */ }
        
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
            self.objectFilterProperty = objectFilterProperty
        } else if let objectFilterProperties = try? container.decode([String].self) {
            self.objectFilterProperties = objectFilterProperties
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
        
        // `and`/`or` are mutually exclusive by contract (see the type's doc
        // comment); a decode failure on one is treated the same as it being
        // absent rather than propagated, so a peer that sends the other one
        // still decodes successfully instead of failing the whole filter.
        do {
            and = try container.decodeIfPresent([ObjectFilterCondition].self, forKey: .and)
         } catch { /* Treated as absent; `or` may still be present. */ }

        do {
            or = try container.decodeIfPresent([ObjectFilterCondition].self, forKey: .or)
         } catch { /* Treated as absent; `and` may still be present. */ }
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

/// A filter expression consisting of a filter operator and its operands.
///
/// Invalid operator/operand combinations are unrepresentable: each case
/// carries exactly the operands its operator requires. For example, `.between`
/// always has two operands, and `.exists` has none.
///
/// The wire format is the unkeyed `[operatorInt, op1?, op2?]` array
/// preserved from the CoatyJS reference; ``ObjectFilterOperator``'s raw
/// values are the wire contract.
///
/// Tip: use one of the typesafe `FilterOperations` functions to construct
/// an expression.
public enum ObjectFilterExpression: Codable, Equatable {

    // MARK: - Cases.

    /// Checks if the filter property is less than the given value.
    case lessThan(FilterOperand)

    /// Checks if the filter property is less than or equal to the given value.
    case lessThanOrEqual(FilterOperand)

    /// Checks if the filter property is greater than the given value.
    case greaterThan(FilterOperand)

    /// Checks if the filter property is greater than or equal to the given value.
    case greaterThanOrEqual(FilterOperand)

    /// Checks if the filter property is between the two given values.
    case between(FilterOperand, FilterOperand)

    /// Checks if the filter property is not between the two given values.
    case notBetween(FilterOperand, FilterOperand)

    /// Checks if the filter property string matches the given pattern.
    ///
    /// The `matcher` is compiled once at decode time and carries no
    /// additional wire data; it is `nil` if the pattern could not be compiled.
    case like(pattern: String, matcher: NSRegularExpression?)

    /// Checks if the filter property is deep equal to the given value.
    case equals(FilterOperand)

    /// Checks if the filter property is not deep equal to the given value.
    case notEquals(FilterOperand)

    /// Checks if the filter property exists.
    case exists

    /// Checks if the filter property doesn't exist.
    case notExists

    /// Checks if the filter property value contains the given values.
    case contains(FilterOperand)

    /// Checks if the filter property value does not contain the given values.
    case notContains(FilterOperand)

    /// Checks if the filter property value is included in the given array.
    case valuesIn([FilterOperand])

    /// Checks if the filter property value is not included in the given array.
    case valuesNotIn([FilterOperand])

    // MARK: - Convenience factory for Like (compiles the pattern).

    /// Creates a `.like` expression, compiling the pattern immediately.
    public static func like(_ pattern: String) -> ObjectFilterExpression {
        .like(pattern: pattern, matcher: ObjectMatcher._createLikeRegexp(pattern: pattern))
    }

    // MARK: - Equatable (matcher is ignored for .like — only the pattern matters).

    public static func == (lhs: ObjectFilterExpression, rhs: ObjectFilterExpression) -> Bool {
        switch (lhs, rhs) {
        case (.lessThan(let l), .lessThan(let r)),
             (.lessThanOrEqual(let l), .lessThanOrEqual(let r)),
             (.greaterThan(let l), .greaterThan(let r)),
             (.greaterThanOrEqual(let l), .greaterThanOrEqual(let r)),
             (.equals(let l), .equals(let r)),
             (.notEquals(let l), .notEquals(let r)),
             (.contains(let l), .contains(let r)),
             (.notContains(let l), .notContains(let r)):
            return l == r
        case (.between(let l1, let l2), .between(let r1, let r2)),
             (.notBetween(let l1, let l2), .notBetween(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.like(let l, _), .like(let r, _)):
            return l == r
        case (.valuesIn(let l), .valuesIn(let r)),
             (.valuesNotIn(let l), .valuesNotIn(let r)):
            return l == r
        case (.exists, .exists), (.notExists, .notExists):
            return true
        default:
            return false
        }
    }

    // MARK: - Codable (wire format: [operatorInt, op1?, op2?]).

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let opInt = try container.decode(Int.self)
        guard let op = ObjectFilterOperator(rawValue: opInt) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(opInt) is not a valid ObjectFilterOperator"
            )
        }
        switch op {
        case .LessThan:
            self = .lessThan(try container.decode(FilterOperand.self))
        case .LessThanOrEqual:
            self = .lessThanOrEqual(try container.decode(FilterOperand.self))
        case .GreaterThan:
            self = .greaterThan(try container.decode(FilterOperand.self))
        case .GreaterThanOrEqual:
            self = .greaterThanOrEqual(try container.decode(FilterOperand.self))
        case .Between:
            self = .between(
                try container.decode(FilterOperand.self),
                try container.decode(FilterOperand.self)
            )
        case .NotBetween:
            self = .notBetween(
                try container.decode(FilterOperand.self),
                try container.decode(FilterOperand.self)
            )
        case .Like:
            let pattern = try container.decode(String.self)
            self = .like(pattern: pattern, matcher: ObjectMatcher._createLikeRegexp(pattern: pattern))
        case .Equals:
            self = .equals(try container.decode(FilterOperand.self))
        case .NotEquals:
            self = .notEquals(try container.decode(FilterOperand.self))
        case .Exists:
            self = .exists
        case .NotExists:
            self = .notExists
        case .Contains:
            self = .contains(try container.decode(FilterOperand.self))
        case .NotContains:
            self = .notContains(try container.decode(FilterOperand.self))
        case .In:
            self = .valuesIn(try container.decode([FilterOperand].self))
        case .NotIn:
            self = .valuesNotIn(try container.decode([FilterOperand].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .lessThan(let v):
            try container.encode(ObjectFilterOperator.LessThan.rawValue)
            try container.encode(v)
        case .lessThanOrEqual(let v):
            try container.encode(ObjectFilterOperator.LessThanOrEqual.rawValue)
            try container.encode(v)
        case .greaterThan(let v):
            try container.encode(ObjectFilterOperator.GreaterThan.rawValue)
            try container.encode(v)
        case .greaterThanOrEqual(let v):
            try container.encode(ObjectFilterOperator.GreaterThanOrEqual.rawValue)
            try container.encode(v)
        case .between(let v1, let v2):
            try container.encode(ObjectFilterOperator.Between.rawValue)
            try container.encode(v1)
            try container.encode(v2)
        case .notBetween(let v1, let v2):
            try container.encode(ObjectFilterOperator.NotBetween.rawValue)
            try container.encode(v1)
            try container.encode(v2)
        case .like(let pattern, _):
            try container.encode(ObjectFilterOperator.Like.rawValue)
            try container.encode(pattern)
        case .equals(let v):
            try container.encode(ObjectFilterOperator.Equals.rawValue)
            try container.encode(v)
        case .notEquals(let v):
            try container.encode(ObjectFilterOperator.NotEquals.rawValue)
            try container.encode(v)
        case .exists:
            try container.encode(ObjectFilterOperator.Exists.rawValue)
        case .notExists:
            try container.encode(ObjectFilterOperator.NotExists.rawValue)
        case .contains(let v):
            try container.encode(ObjectFilterOperator.Contains.rawValue)
            try container.encode(v)
        case .notContains(let v):
            try container.encode(ObjectFilterOperator.NotContains.rawValue)
            try container.encode(v)
        case .valuesIn(let vs):
            try container.encode(ObjectFilterOperator.In.rawValue)
            try container.encode(vs)
        case .valuesNotIn(let vs):
            try container.encode(ObjectFilterOperator.NotIn.rawValue)
            try container.encode(vs)
        }
    }
}

/// Defines filter operator functions that yield ``ObjectFilterExpression``
/// values.
///
/// Each function takes a ``FilterOperand`` (which is
/// `ExpressibleBy*Literal`, so literals like `42`, `"abc"`, `[1, 2, 3]` are
/// accepted directly) and returns the corresponding expression case.
public enum FilterOperations {

    /// Checks if the filter property is less than the given value.
    public static func lessThan(_ value: FilterOperand) -> ObjectFilterExpression {
        .lessThan(value)
    }

    /// Checks if the filter property is less than or equal to the given value.
    public static func lessThanOrEqual(_ value: FilterOperand) -> ObjectFilterExpression {
        .lessThanOrEqual(value)
    }

    /// Checks if the filter property is greater than the given value.
    public static func greaterThan(_ value: FilterOperand) -> ObjectFilterExpression {
        .greaterThan(value)
    }

    /// Checks if the filter property is greater than or equal to the given value.
    public static func greaterThanOrEqual(_ value: FilterOperand) -> ObjectFilterExpression {
        .greaterThanOrEqual(value)
    }

    /// Checks if the filter property is between the two given values.
    public static func between(_ value1: FilterOperand, _ value2: FilterOperand) -> ObjectFilterExpression {
        .between(value1, value2)
    }

    /// Checks if the filter property is not between the two given values.
    public static func notBetween(_ value1: FilterOperand, _ value2: FilterOperand) -> ObjectFilterExpression {
        .notBetween(value1, value2)
    }

    /// Checks if the filter property string matches the given LIKE pattern.
    public static func like(pattern: String) -> ObjectFilterExpression {
        .like(pattern)
    }

    /// Checks if the filter property exists.
    public static func exists() -> ObjectFilterExpression {
        .exists
    }

    /// Checks if the filter property doesn't exist.
    public static func notExists() -> ObjectFilterExpression {
        .notExists
    }

    /// Checks if the filter property is deep equal to the given value.
    public static func equals(_ value: FilterOperand) -> ObjectFilterExpression {
        .equals(value)
    }

    /// Checks if the filter property is not deep equal to the given value.
    public static func notEquals(_ value: FilterOperand) -> ObjectFilterExpression {
        .notEquals(value)
    }

    /// Checks if the filter property value contains the given values.
    public static func contains(_ value: FilterOperand) -> ObjectFilterExpression {
        .contains(value)
    }

    /// Checks if the filter property value does not contain the given values.
    public static func notContains(_ value: FilterOperand) -> ObjectFilterExpression {
        .notContains(value)
    }

    /// Checks if the filter property value is included in the given array.
    public static func valuesIn(_ values: [FilterOperand]) -> ObjectFilterExpression {
        .valuesIn(values)
    }

    /// Checks if the filter property value is not included in the given array.
    public static func valuesNotIn(_ values: [FilterOperand]) -> ObjectFilterExpression {
        .valuesNotIn(values)
    }
}

/// Defines filter operator constants for object filter conditions.
public enum ObjectFilterOperator: Int {

    /// Checks if the filter property is less than the given value. For string
    /// comparison, a default lexical ordering is used. Note: Do not compare a
    /// number with a string, as the result is not defined.
    case LessThan

    /// Checks if the filter property is less than or equal to the given value.
    /// For string comparison, a default lexical ordering is used. Note: Do not
    /// compare a number with a string, as the result is not defined.
    case LessThanOrEqual

    /// Checks if the filter property is greater than the given value. For
    /// string comparison, a default lexical ordering is used. Note: Do not
    /// compare a number with a string, as the result is not defined.
    case GreaterThan
    
    /// Checks if the filter property is greater than or equal to the given value.
    /// For string comparison, a default lexical ordering is used.
    /// Note: Do not compare a number with a string, as the result is not defined.
    case GreaterThanOrEqual

    /// Checks if the filter property is between the two given operands, i.e.
    /// prop >= operand AND prop <= operand2. If the first operand is not less
    /// than or equal to the second operand, those two arguments are
    /// automatically swapped. For string comparison, a default lexical ordering
    /// is used. Note: Do not compare a number with a string, as the result is
    /// not defined.
    case Between

    /// Checks if the filter property is not between the given operands, i.e.
    /// prop < operand1 OR prop > operand2. If the first operand is not less
    /// than or equal to the second operand, those two arguments are
    /// automatically swapped. For string comparison, a default lexical ordering
    /// is used. Note: Do not compare a number with a string, as the result is
    /// not defined.
    case NotBetween

    /// Checks if the filter property string matches the given pattern. If
    /// pattern does not contain percent signs or underscores, then the pattern
    /// only represents the string itself; in that case LIKE acts like the
    /// equals operator (but less performant). An underscore (_) in pattern
    /// stands for (matches) any single character; a percent sign (%) matches
    /// any sequence of zero or more characters.
    ///
    /// LIKE pattern matching always covers the entire string. Therefore, if
    /// it's desired to match a sequence anywhere within a string, the pattern
    /// must start and end with a percent sign.
    ///
    /// To match a literal underscore or percent sign without matching other
    /// characters, the respective character in pattern must be preceded by the
    /// escape character. The default escape character is the backslash. To
    /// match the escape character itself, write two escape characters.
    ///
    /// For example, the pattern string `%a_c\\d\_` matches `abc\d_` in `hello
    /// abc\d_` and `acc\d_` in `acc\d_`, but nothing in `hello abc\d_world`.
    /// Note that in programming languages like JavaScript, Java, or C#, where
    /// the backslash character is used as escape character for certain special
    /// characters you have to double backslashes in literal string constants.
    /// Thus, for the example above the pattern string literal would look like
    /// `"%a_c\\\\d\\_"`.
    case Like

    /// Checks if the filter property is deep equal to the given value according
    /// to a recursive equality algorithm.
    case Equals

    /// Checks if the filter property is not deep equal to the given value
    /// according to a recursive equality algorithm.
    case NotEquals

    /// Checks if the filter property exists.
    case Exists

    /// Checks if the filter property doesn't exist.
    case NotExists

    /// Checks if the filter property value (usually an object or array)
    /// contains the given values. Primitive value types (number, string,
    /// boolean, null) contain only the identical value. Object properties match
    /// if all the key-value pairs of the specified object are contained in
    /// them. Array properties match if all the specified array elements are
    /// contained in them.
    ///
    /// The general principle is that the contained object must match the
    /// containing object as to structure and data contents recursively on all
    /// levels, possibly after discarding some non-matching array elements or
    /// object key/value pairs from the containing object. But remember that the
    /// order of array elements is not significant when doing a containment
    /// match, and duplicate array elements are effectively considered only
    /// once.
    ///
    /// As a special exception to the general principle that the structures must
    /// match, an array on *toplevel* may contain a primitive value:
    ///
    /// ```
    /// Contains([1, 2, 3], [3]) => true
    /// Contains([1, 2, 3], 3) => true
    /// ```
    case Contains

    /// Checks if the filter property value (usually an object or array) does
    /// not contain the given values. Primitive value types (number, string,
    /// boolean, null) contain only the identical value. Object properties match
    /// if all the key-value pairs of the specified object are not contained in
    /// them. Array properties match if all the specified array elements are not
    /// contained in them.
    ///
    /// The general principle is that the contained object must match the
    /// containing object as to structure and data contents recursively on all
    /// levels, possibly after discarding some non-matching array elements or
    /// object key/value pairs from the containing object. But remember that the
    /// order of array elements is not significant when doing a containment
    /// match, and duplicate array elements are effectively considered only
    /// once.
    ///
    /// As a special exception to the general principle that the structures must
    /// match, an array on///toplevel* may contain a primitive value:
    ///
    /// ```
    /// NotContains([1, 2, 3], [4]) => true
    /// NotContains([1, 2, 3], 4) => true
    /// ```
    case NotContains

    /// Checks if the filter property value is included on toplevel in the given
    /// operand array of values which may be primitive types (number, string,
    /// boolean, null) or object types compared using the deep equality
    /// operator.
    ///
    /// For example:
    ///
    /// ```
    /// In(47, [1, 46, 47, "foo"]) => true
    /// In(47, [1, 46, "47", "foo"]) => false
    /// In({ "foo": 47 }, [1, 46, { "foo": 47 }, "foo"]) => true
    /// In({ "foo": 47 }, [1, 46, { "foo": 47, "bar": 42 }, "foo"]) => false
    /// ```
    case In

    /// Checks if the filter property value is not included on toplevel in the given
    /// operand array of values which may be primitive types (number, string, boolean, null)
    /// or object types compared using the deep equality operator.
    ///
    /// For example:
    ///
    /// ```
    /// NotIn(47, [1, 46, 47, "foo"]) => false
    /// NotIn(47, [1, 46, "47", "foo"]) => true
    /// NotIn({ "foo": 47 }, [1, 46, { "foo": 47 }, "foo"]) => false
    /// NotIn({ "foo": 47 }, [1, 46, { "foo": 47, "bar": 42 }, "foo"]) => true
    /// ```
    case NotIn
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
