//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  ObjectFilterOperator.swift
//  Axoloty
//

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

    /// Checks whether the candidate property value contains the requested
    /// value. Strings use substring containment, so `Contains("abc", "bc")`,
    /// `Contains("abc", "")`, and `Contains("", "x")` evaluate to `true`,
    /// `true`, and `false`, respectively. Other primitive values contain only
    /// the identical value. Object properties contain the requested object if
    /// all its key-value pairs are present recursively, and array properties
    /// contain the requested array if all its elements are present.
    ///
    /// The general principle is that the contained object must match the
    /// containing object as to structure and data contents recursively on all
    /// levels, possibly after discarding some non-matching array elements or
    /// object key/value pairs from the containing object. But remember that the
    /// order of array elements is not significant when doing a containment
    /// match, and duplicate array elements are effectively considered only
    /// once.
    ///
    /// An empty requested object or array is contained by any candidate object
    /// or array of the corresponding kind. As a special exception to the
    /// general principle that the structures must match, an array at the top
    /// level may contain a primitive value:
    ///
    /// ```
    /// Contains([1, 2, 3], [3]) => true
    /// Contains([1, 2, 3], 3) => true
    /// ```
    case Contains

    /// Checks whether the candidate property value does not contain the
    /// requested value according to ``Contains`` semantics. Strings use
    /// substring containment, so `NotContains("abc", "")` and
    /// `NotContains("", "x")` evaluate to `false` and `true`, respectively.
    /// Other primitive values require inequality. Objects and arrays negate
    /// the recursive key-value and element containment checks described by
    /// ``Contains``; therefore, an empty requested object is never
    /// `NotContains` from a candidate object.
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
    /// match, an array at the top level may contain a primitive value:
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
