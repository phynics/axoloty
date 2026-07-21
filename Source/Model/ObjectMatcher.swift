//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  ObjectMatcher.swift
//  Axoloty

import Foundation
import IkigaJSON

/// Provides a static `matchesFilter` method to match an object against a
/// given object filter. Useful for retrieving matching objects on Query events
/// without using a database adapter. Also useful to filter out Coaty objects
/// that match given filter conditions before publishing with Advertise or
/// Channel events.
public enum ObjectMatcher {
    
    // MARK: - Public methods.
    
    /// Determines whether the given object matches the given context filter.
    /// Note that if you pass in an `ObjectFilter`, only the filter conditions are
    /// heeded for the result.
    /// - Parameters:
    ///     - obj: The object to pass the filter on (optional).
    ///     - filter: The context filter to apply (optional).
    /// - Returns: true: on match; false otherwise
    public static func matchesFilter(obj: CoatyObject?, filter: ContextFilter?) -> Bool {
        if obj == nil {
            return false
        }
        if filter == nil {
            return true
        }
        if filter?.condition == nil && filter?.conditions == nil {
            return true
        }
        
        // If both condition and conditions.and are not nil, check the condition and
        // logically 'and' it with the conditions.and
        if let singleCondition = filter?.condition, let multipleConditionsAnd = filter?.conditions?.and {
            let singleConditionResult = ObjectMatcher._matchesCondition(obj: obj!,
                                                                         condition: singleCondition)

            let multipleConditionsAndResult = multipleConditionsAnd.allSatisfy { cond -> Bool in
                return ObjectMatcher._matchesCondition(obj: obj!,
                                                       condition: cond)
            }
            
            return singleConditionResult && multipleConditionsAndResult
        }
        
        // If both condition and conditions.or are not nil, check the condition and
        // logically 'and' it with the conditions
        if let singleCondition = filter?.condition, let multipleConditionsOr = filter?.conditions?.or {
            let singleConditionResult = ObjectMatcher._matchesCondition(obj: obj!,
                                                                         condition: singleCondition)

            let multipleConditionsOrResult = multipleConditionsOr.contains { cond -> Bool in
                return ObjectMatcher._matchesCondition(obj: obj!,
                                                       condition: cond)
            }
            
            return singleConditionResult && multipleConditionsOrResult
        }
        
        if let singleCondition = filter?.condition {
            return ObjectMatcher._matchesCondition(obj: obj!,
                                                   condition: singleCondition)
        }
        if let multipleConditionsAnd = filter?.conditions?.and {
            return multipleConditionsAnd.allSatisfy { cond -> Bool in
                return ObjectMatcher._matchesCondition(obj: obj!,
                                                       condition: cond)
            }
        }
        if let multipleConditionsOr = filter?.conditions?.or {
            return multipleConditionsOr.contains { cond -> Bool in
                return ObjectMatcher._matchesCondition(obj: obj!,
                                                       condition: cond)
            }
        }
        
        return true
    }
    
    // MARK: - Internal methods.
    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Gets an array of property names for the given nested properties specified either
    /// in dot notation or array notation.
    ///
    /// - Parameters:
    ///     - propNames property names as string in dot notation or as array of property names
    /// - Returns: an array of nested property names
    internal static func getFilterProperties(propNames: ObjectFilterProperty) -> [String] {
        if let singleString = propNames.objectFilterProperty {
            return singleString.split(separator: Character(".")).map(String.init)
        } else if let multipleStrings = propNames.objectFilterProperties {
            return multipleStrings
        } else {
            return []
        }
    }
    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Gets the value of a given property for the given object. Property names may be
    /// specified to retrieve the value of a nested property of a subordinate object.
    ///
    /// - Parameters:
    ///     - propNames: property names as string in dot notation or as array of property names
    ///     - obj: a Coaty object
    /// - Returns: the value of the nested properties of the given object as FilterOperand (nil if no such property has been found or any other error has occured)
    internal static func getFilterPropertyValue(propNames: ObjectFilterProperty, obj: CoatyObject) -> FilterOperand? {
        let propertyNames = ObjectMatcher.getFilterProperties(propNames: propNames)
        guard !propertyNames.isEmpty else { return nil }

        let root = obj.rawJSONObject ?? (try? JSONObject(data: Data(obj.json.utf8)))
        guard var current: any IkigaJSON.JSONValue = root else { return nil }

        for propertyName in propertyNames {
            guard let object = current.object, let next = object[propertyName] else {
                return nil
            }
            current = next
        }

        return FilterOperand.fromJSONValue(current)
    }
    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Gets the value of a given property for the given object. Property names may be
    /// specified to retrieve the value of a nested property of a subordinate object.
    ///
    /// - Parameters:
    ///     - propNames property names as an array of property names (already in a correct format)
    ///     - obj: a Coaty object
    /// - Returns: the value of the nested properties of the given object

    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Recursively list all properties of an AnyObject.
    ///
    /// - Parameters:
    ///     - structure: any object from which properties can be extracted (either a CoatyObject or Dictionary)
    /// - Returns: a tuple list that contains all attributes and their values representes as Any.

    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Recursively list all properties of a Swift object.
    ///
    /// - Parameters:
    ///     - mirror: a mirror of an object from which properties are to be extracted.
    /// - Returns: a tuple list that contains all attributes and their values representes as Any.

    
    /// - Note: Internal For internal use in framework only.
    ///
    /// Check if a coaty object satisfies the condition.
    ///
    /// - Parameters:
    ///     - obj: coaty object to check
    ///     - condition: considered condition
    /// - Returns: true if object satisfies the condition; false otherwise
    internal static func _matchesCondition(obj: CoatyObject, condition: ObjectFilterCondition) -> Bool {
        let v = ObjectMatcher.getFilterPropertyValue(propNames: condition.property, obj: obj)
        if v == nil { print("FILTER MISS", condition.property.objectFilterProperty ?? "array") }
        switch condition.expression {
        case .notExists:
            return v == nil
        case .exists:
            return v != nil
        case .lessThan(let v1):
            guard let v else { return false }
            return v < v1
        case .lessThanOrEqual(let v1):
            guard let v else { return false }
            return v <= v1
        case .greaterThan(let v1):
            guard let v else { return false }
            return v > v1
        case .greaterThanOrEqual(let v1):
            guard let v else { return false }
            return v >= v1
        case .equals(let v1):
            guard let v else { return false }
            return v == v1
        case .notEquals(let v1):
            guard let v else { return false }
            return v != v1
        case .between(let v1, let v2):
            guard let v else { return false }
            let lower = v1 > v2 ? v2 : v1
            let upper = v1 > v2 ? v1 : v2
            return v >= lower && v <= upper
        case .notBetween(let v1, let v2):
            guard let v else { return false }
            let lower = v1 > v2 ? v2 : v1
            let upper = v1 > v2 ? v1 : v2
            return !(v >= lower && v <= upper)
        case .like(_, let matcher):
            guard let v, case .string(let stringValue) = v else { return false }
            guard let regex = matcher else { return false }
            return regex._matches(stringValue)
        case .contains(let v1):
            guard let v else { return false }
            return FilterOperand.deepContains(v, v1)
        case .notContains(let v1):
            guard let v else { return false }
            return !FilterOperand.deepContains(v, v1)
        case .valuesIn(let values):
            guard let v else { return false }
            return FilterOperand.deepIncludes(.array(values), v)
        case .valuesNotIn(let values):
            guard let v else { return false }
            return !FilterOperand.deepIncludes(.array(values), v)
        }
    }
    
    internal static func _createLikeRegexp(pattern: String) -> NSRegularExpression? {
        // Convert underscore/percent based SQL LIKE pattern into Swift NSRegularExpression regex syntax
        var regexStr = "^"
        var isEscaped = false
        for c in pattern {
            if c == "\\" {
                if isEscaped {
                    isEscaped = false
                    regexStr += "\\\\"
                } else {
                    isEscaped = true
                }
            } else if ".*+?^${}()|[]/".contains(c) {
                regexStr += "\\" + "\(c)"
                isEscaped = false
            } else if c == "_" && !isEscaped {
                regexStr += "."
            } else if c == "%" && !isEscaped {
                regexStr += ".*"
            } else {
                regexStr += "\(c)"
            }
        }
        regexStr += "$"
        
        return try? NSRegularExpression(pattern: regexStr, options: .anchorsMatchLines)
    }
}

extension NSRegularExpression {
    func _matches(_ string: String) -> Bool {
        let range = NSRange(location: 0, length: string.utf16.count)
        let result = firstMatch(in: string, options: [], range: range)
        return result != nil
    }
}
