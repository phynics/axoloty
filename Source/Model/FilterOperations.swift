//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  FilterOperations.swift
//  Axoloty
//

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

    /// Checks containment: strings use substring matching; arrays contain every requested
    /// element; and objects contain every requested key-value pair, recursively. Other
    /// primitive values require equality.
    public static func contains(_ value: FilterOperand) -> ObjectFilterExpression {
        .contains(value)
    }

    /// Checks if the candidate property value does not contain the requested
    /// value according to ``contains(_:)`` semantics.
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
