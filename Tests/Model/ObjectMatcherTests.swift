//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  ObjectMatcherTests.swift
//  Axoloty

import Testing
import Axoloty
import Foundation

@Suite
struct ObjectMatcherTests {

    @Test

    func testMatchesFilterSingleCondition() throws {
        let obj = CoatyObject(coreType: .Log,
                              objectType: Log.objectType,
                              objectId: .init(),
                              name: "Hello")

        let filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("name"),
                                                                   expression: .equals("Hello")))

        #expect(ObjectMatcher.matchesFilter(obj: obj, filter: filter))
    }

    @Test

    func testMatchesFilterAndConditions() throws {
        let dotTest2: [String: Any] = [
            "hello": "hello"
        ]

        let dotTest1: [String: Any] = [
            ".": dotTest2
        ]

        let nestedDictionary: [String: Any] = [
            "lastProperty": 42,
            ".": dotTest1
        ]

        let nestedObject = Log(logLevel: .info,
                               logMessage: "ABCD",
                               logDate: "22.01.2001",
                               name: "ABBBBC",
                               objectType: Log.objectType,
                               objectId: .init(),
                               logLabels: nestedDictionary)

        let simpleLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42")
        let simpleLog2 = Log(logLevel: .info, logMessage: "Hello", logDate: "43")
        let complexLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42", name: "LogObject", objectType: Log.objectType, objectId: simpleLog.objectId)

        // Create hierarchy of objects used for testing.
        let logLabels: [String: Any] = [
            "boolean": true,
            "number": 42,
            "string": "Abc",
            "array": [42, [43, 44], [[45, 46]]],
            "array1": [1, 2, 3],
            "array2": [1, [2, 3, 4], 3],
            "filterLikeString": "hello abc\\d_",
            "filterLikeString1": ".*+?^${}()|[]",
            "filterLikeString2": "/",
            ".": 42,
            "nestedObject": nestedObject,
            "complexLog": complexLog
        ]

        let thirdObject = Log(logLevel: .info,
                              logMessage: "ABC",
                              logDate: "22.01.2001",
                              name: "AbCC",
                              objectType: Log.objectType,
                              objectId: .init(),
                              logTags: ["Tag1", "Tag2"],
                              logLabels: logLabels,
                              logHost: nil)

        let secondObject = Snapshot(creationTimestamp: 1.0,
                                    creatorId: .init(),
                                    object: thirdObject)

        let firstObject = Snapshot(creationTimestamp: 2.0,
                                   creatorId: .init(),
                                   object: secondObject)

        // Initialize the filter object
        // NOTE: It is impossible to create an empty filter with provided intializers, that's why condition and conditions have to be nilled later
        var filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("_"),
                                                                   expression: .exists))
        filter.condition = nil
        filter.conditions = nil

        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: nil)))
        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: filter)))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: nil))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))

        // Create new filter with 'and' conditions
        let conditions: [ObjectFilterCondition] = [
            // MARK: - Test: .Exists and .NotExists; .Equals and .NotEquals for primitives.
            ObjectFilterCondition(property: ObjectFilterProperty("foo"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("foo.bar"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logHost"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .equals(true)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .notEquals(false)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notEquals(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .equals("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notEquals("abc")),

            // MARK: - Test: Object nested in Dictionary nested in Object
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.lastProperty"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.foo"),
                                  expression: .notExists),

            // MARK: - Test: .Equals and .NotEquals for arrays.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .equals([42, [43, 44], [[45, 46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notEquals([42, [43, 44], [[45, 47]]])),

            // MARK: - Test: .Equals and .NotEquals for objects.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .equals(FilterOperand(Log(logLevel: .info,
                                                                                                                  logMessage: "ABC",
                                                                                                                  logDate: "22.01.2001",
                                                                                                                  name: "AbCC",
                                                                                                                  objectType: Log.objectType,
                                                                                                                  objectId: thirdObject.objectId,
                                                                                                                  logTags: ["Tag1", "Tag2"],
                                                                                                                  logLabels: logLabels,
                                                                                                                  logHost: nil)))),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .notEquals(FilterOperand(Log(logLevel: .info,
                                                                                                                     logMessage: "...",
                                                                                                                     logDate: "...",
                                                                                                                     name: "...",
                                                                                                                     objectType: Log.objectType,
                                                                                                                     objectId: .init(),
                                                                                                                     logTags: ["Tag1", "Tag2"],
                                                                                                                     logLabels: logLabels,
                                                                                                                     logHost: nil)))),

            // MARK: - TEST: Properties with dot names and properties specified as array
            ObjectFilterCondition(property: ObjectFilterProperty(["object", "object", "logLabels", "nestedObject", "logLabels", ".", ".", "hello"]),
                                  expression: .equals("hello")),

            // MARK: - Test: .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThan(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThan("Abce")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThanOrEqual("ABc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThan(41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThan("abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThanOrEqual("Abc")),

            // MARK: - Test: .Between
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(42, 42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(41, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(43, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abc", "Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abb", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abd", "Abb")),

            // MARK: - Test: .NotBetween
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(43, 47)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(47, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(41, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abd", "Abf")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abf", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abb", "Abb")),

            // MARK: - Test: .Like
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Ab_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_b_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%__")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%bc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString"),
                                  expression: .like("%a_c\\\\d\\_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString1"),
                                  expression: .like(".*+?^${}()|[]")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString2"),
                                  expression: .like("\\/")),

            // MARK: - Test: .Contains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42, [43], [[46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1, 3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .contains([3, [3, 2]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .contains(FilterOperand(simpleLog))),

            // MARK: - Test: .NotContains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains([41, [45], [[43]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .notContains([3, 1, 5])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .notContains([3, [3, 1]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .notContains(FilterOperand(simpleLog2))),

            // MARK: - Test: .In
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesIn([43, 42, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesIn([43, 42, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesIn([43, true, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        name: "AbCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

            // MARK: - Test: .NotIn
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesNotIn([43, 41, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesNotIn([43, 42, "abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesNotIn([43, false, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesNotIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        // Only name property is not the same as in object.object
                                        name: "AbCCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

        ]

        filter = ObjectFilter(conditions: ObjectFilterConditions(and: conditions))

        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))
    }

    @Test

    func testMatchesFilterOrConditions() throws {
        let dotTest2: [String: Any] = [
            "hello": "hello"
        ]

        let dotTest1: [String: Any] = [
            ".": dotTest2
        ]

        let nestedDictionary: [String: Any] = [
            "lastProperty": 42,
            ".": dotTest1
        ]

        let nestedObject = Log(logLevel: .info,
                               logMessage: "ABCD",
                               logDate: "22.01.2001",
                               name: "ABBBBC",
                               objectType: Log.objectType,
                               objectId: .init(),
                               logLabels: nestedDictionary)

        let simpleLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42")
        let simpleLog2 = Log(logLevel: .info, logMessage: "Hello", logDate: "43")
        let complexLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42", name: "LogObject", objectType: Log.objectType, objectId: simpleLog.objectId)

        // Create hierarchy of objects used for testing.
        let logLabels: [String: Any] = [
            "boolean": true,
            "number": 42,
            "string": "Abc",
            "array": [42, [43, 44], [[45, 46]]],
            "array1": [1, 2, 3],
            "array2": [1, [2, 3, 4], 3],
            "filterLikeString": "hello abc\\d_",
            "filterLikeString1": ".*+?^${}()|[]",
            "filterLikeString2": "/",
            ".": 42,
            "nestedObject": nestedObject,
            "complexLog": complexLog
        ]

        let thirdObject = Log(logLevel: .info,
                              logMessage: "ABC",
                              logDate: "22.01.2001",
                              name: "AbCC",
                              objectType: Log.objectType,
                              objectId: .init(),
                              logTags: ["Tag1", "Tag2"],
                              logLabels: logLabels,
                              logHost: nil)

        let secondObject = Snapshot(creationTimestamp: 1.0,
                                    creatorId: .init(),
                                    object: thirdObject)

        let firstObject = Snapshot(creationTimestamp: 2.0,
                                   creatorId: .init(),
                                   object: secondObject)

        // Initialize the filter object
        // NOTE: It is impossible to create an empty filter with provided intializers, that's why condition and conditions have to be nilled later
        var filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("_"),
                                                                   expression: .exists))
        filter.condition = nil
        filter.conditions = nil

        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: nil)))
        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: filter)))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: nil))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))

        // Create new filter with 'and' conditions
        let conditions: [ObjectFilterCondition] = [
            // MARK: - Test: .Exists and .NotExists; .Equals and .NotEquals for primitives.
            ObjectFilterCondition(property: ObjectFilterProperty("foo"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("foo.bar"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logHost"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .equals(true)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .notEquals(false)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notEquals(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .equals("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notEquals("abc")),

            // MARK: - Test: Object nested in Dictionary nested in Object
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.lastProperty"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.foo"),
                                  expression: .notExists),

            // MARK: - Test: .Equals and .NotEquals for arrays.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .equals([42, [43, 44], [[45, 46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notEquals([42, [43, 44], [[45, 47]]])),

            // MARK: - Test: .Equals and .NotEquals for objects.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .equals(FilterOperand(Log(logLevel: .info,
                                                                                                                  logMessage: "ABC",
                                                                                                                  logDate: "22.01.2001",
                                                                                                                  name: "AbCC",
                                                                                                                  objectType: Log.objectType,
                                                                                                                  objectId: thirdObject.objectId,
                                                                                                                  logTags: ["Tag1", "Tag2"],
                                                                                                                  logLabels: logLabels,
                                                                                                                  logHost: nil)))),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .notEquals(FilterOperand(Log(logLevel: .info,
                                                                                                                     logMessage: "...",
                                                                                                                     logDate: "...",
                                                                                                                     name: "...",
                                                                                                                     objectType: Log.objectType,
                                                                                                                     objectId: .init(),
                                                                                                                     logTags: ["Tag1", "Tag2"],
                                                                                                                     logLabels: logLabels,
                                                                                                                     logHost: nil)))),

            // MARK: - TEST: Properties with dot names and properties specified as array
            ObjectFilterCondition(property: ObjectFilterProperty(["object", "object", "logLabels", "nestedObject", "logLabels", ".", ".", "hello"]),
                                  expression: .equals("hello")),

            // MARK: - Test: .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThan(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThan("Abce")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThanOrEqual("ABc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThan(41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThan("abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThanOrEqual("Abc")),

            // MARK: - Test: .Between
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(42, 42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(41, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(43, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abc", "Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abb", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abd", "Abb")),

            // MARK: - Test: .NotBetween
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(43, 47)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(47, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(41, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abd", "Abf")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abf", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abb", "Abb")),

            // MARK: - Test: .Like
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Ab_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_b_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%__")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%bc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString"),
                                  expression: .like("%a_c\\\\d\\_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString1"),
                                  expression: .like(".*+?^${}()|[]")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString2"),
                                  expression: .like("\\/")),

            // MARK: - Test: .Contains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42, [43], [[46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1, 3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .contains([3, [3, 2]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .contains(FilterOperand(simpleLog))),

            // MARK: - Test: .NotContains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains([41, [45], [[43]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .notContains([3, 1, 5])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .notContains([3, [3, 1]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .notContains(FilterOperand(simpleLog2))),

            // MARK: - Test: .In
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesIn([43, 42, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesIn([43, 42, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesIn([43, true, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        name: "AbCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

            // MARK: - Test: .NotIn
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesNotIn([43, 41, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesNotIn([43, 42, "abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesNotIn([43, false, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesNotIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        // Only name property is not the same as in object.object
                                        name: "AbCCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

        ]

        filter = ObjectFilter(conditions: ObjectFilterConditions(or: conditions))

        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))
    }

    @Test

    func testBothSingleConditionAndAndCondtions() throws {
        // For single condition
        let singleCondition = ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                                    expression: .equals("Abc"))

        // For And conditions
        let dotTest2: [String: Any] = [
            "hello": "hello"
        ]

        let dotTest1: [String: Any] = [
            ".": dotTest2
        ]

        let nestedDictionary: [String: Any] = [
            "lastProperty": 42,
            ".": dotTest1
        ]

        let nestedObject = Log(logLevel: .info,
                               logMessage: "ABCD",
                               logDate: "22.01.2001",
                               name: "ABBBBC",
                               objectType: Log.objectType,
                               objectId: .init(),
                               logLabels: nestedDictionary)

        let simpleLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42")
        let simpleLog2 = Log(logLevel: .info, logMessage: "Hello", logDate: "43")
        let complexLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42", name: "LogObject", objectType: Log.objectType, objectId: simpleLog.objectId)

        // Create hierarchy of objects used for testing.
        let logLabels: [String: Any] = [
            "boolean": true,
            "number": 42,
            "string": "Abc",
            "array": [42, [43, 44], [[45, 46]]],
            "array1": [1, 2, 3],
            "array2": [1, [2, 3, 4], 3],
            "filterLikeString": "hello abc\\d_",
            "filterLikeString1": ".*+?^${}()|[]",
            "filterLikeString2": "/",
            ".": 42,
            "nestedObject": nestedObject,
            "complexLog": complexLog
        ]

        let thirdObject = Log(logLevel: .info,
                              logMessage: "ABC",
                              logDate: "22.01.2001",
                              name: "AbCC",
                              objectType: Log.objectType,
                              objectId: .init(),
                              logTags: ["Tag1", "Tag2"],
                              logLabels: logLabels,
                              logHost: nil)

        let secondObject = Snapshot(creationTimestamp: 1.0,
                                    creatorId: .init(),
                                    object: thirdObject)

        let firstObject = Snapshot(creationTimestamp: 2.0,
                                   creatorId: .init(),
                                   object: secondObject)

        // Initialize the filter object
        // NOTE: It is impossible to create an empty filter with provided intializers, that's why condition and conditions have to be nilled later
        var filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("_"),
                                                                   expression: .exists))
        filter.condition = nil
        filter.conditions = nil

        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: nil)))
        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: filter)))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: nil))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))

        // Create new filter with 'and' conditions
        let conditions: [ObjectFilterCondition] = [
            // MARK: - Test: .Exists and .NotExists; .Equals and .NotEquals for primitives.
            ObjectFilterCondition(property: ObjectFilterProperty("foo"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("foo.bar"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logHost"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .equals(true)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .notEquals(false)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notEquals(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .equals("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notEquals("abc")),

            // MARK: - Test: Object nested in Dictionary nested in Object
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.lastProperty"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.foo"),
                                  expression: .notExists),

            // MARK: - Test: .Equals and .NotEquals for arrays.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .equals([42, [43, 44], [[45, 46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notEquals([42, [43, 44], [[45, 47]]])),

            // MARK: - Test: .Equals and .NotEquals for objects.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .equals(FilterOperand(Log(logLevel: .info,
                                                                                                                  logMessage: "ABC",
                                                                                                                  logDate: "22.01.2001",
                                                                                                                  name: "AbCC",
                                                                                                                  objectType: Log.objectType,
                                                                                                                  objectId: thirdObject.objectId,
                                                                                                                  logTags: ["Tag1", "Tag2"],
                                                                                                                  logLabels: logLabels,
                                                                                                                  logHost: nil)))),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .notEquals(FilterOperand(Log(logLevel: .info,
                                                                                                                     logMessage: "...",
                                                                                                                     logDate: "...",
                                                                                                                     name: "...",
                                                                                                                     objectType: Log.objectType,
                                                                                                                     objectId: .init(),
                                                                                                                     logTags: ["Tag1", "Tag2"],
                                                                                                                     logLabels: logLabels,
                                                                                                                     logHost: nil)))),

            // MARK: - TEST: Properties with dot names and properties specified as array
            ObjectFilterCondition(property: ObjectFilterProperty(["object", "object", "logLabels", "nestedObject", "logLabels", ".", ".", "hello"]),
                                  expression: .equals("hello")),

            // MARK: - Test: .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThan(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThan("Abce")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThanOrEqual("ABc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThan(41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThan("abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThanOrEqual("Abc")),

            // MARK: - Test: .Between
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(42, 42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(41, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(43, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abc", "Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abb", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abd", "Abb")),

            // MARK: - Test: .NotBetween
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(43, 47)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(47, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(41, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abd", "Abf")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abf", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abb", "Abb")),

            // MARK: - Test: .Like
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Ab_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_b_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%__")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%bc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString"),
                                  expression: .like("%a_c\\\\d\\_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString1"),
                                  expression: .like(".*+?^${}()|[]")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString2"),
                                  expression: .like("\\/")),

            // MARK: - Test: .Contains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42, [43], [[46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1, 3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .contains([3, [3, 2]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .contains(FilterOperand(simpleLog))),

            // MARK: - Test: .NotContains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains([41, [45], [[43]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .notContains([3, 1, 5])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .notContains([3, [3, 1]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .notContains(FilterOperand(simpleLog2))),

            // MARK: - Test: .In
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesIn([43, 42, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesIn([43, 42, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesIn([43, true, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        name: "AbCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

            // MARK: - Test: .NotIn
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesNotIn([43, 41, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesNotIn([43, 42, "abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesNotIn([43, false, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesNotIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        // Only name property is not the same as in object.object
                                        name: "AbCCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

        ]

        filter = ObjectFilter(conditions: ObjectFilterConditions(and: conditions))

        // Edge case
        filter.condition = singleCondition

        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))
    }

    @Test

    func testBothSingleConditionAndOrCondtions() throws {
        // For single condition
        let singleCondition = ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                                    expression: .equals("Abc"))

        // For And conditions
        let dotTest2: [String: Any] = [
            "hello": "hello"
        ]

        let dotTest1: [String: Any] = [
            ".": dotTest2
        ]

        let nestedDictionary: [String: Any] = [
            "lastProperty": 42,
            ".": dotTest1
        ]

        let nestedObject = Log(logLevel: .info,
                               logMessage: "ABCD",
                               logDate: "22.01.2001",
                               name: "ABBBBC",
                               objectType: Log.objectType,
                               objectId: .init(),
                               logLabels: nestedDictionary)

        let simpleLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42")
        let simpleLog2 = Log(logLevel: .info, logMessage: "Hello", logDate: "43")
        let complexLog = Log(logLevel: .info, logMessage: "Hello", logDate: "42", name: "LogObject", objectType: Log.objectType, objectId: simpleLog.objectId)

        // Create hierarchy of objects used for testing.
        let logLabels: [String: Any] = [
            "boolean": true,
            "number": 42,
            "string": "Abc",
            "array": [42, [43, 44], [[45, 46]]],
            "array1": [1, 2, 3],
            "array2": [1, [2, 3, 4], 3],
            "filterLikeString": "hello abc\\d_",
            "filterLikeString1": ".*+?^${}()|[]",
            "filterLikeString2": "/",
            ".": 42,
            "nestedObject": nestedObject,
            "complexLog": complexLog
        ]

        let thirdObject = Log(logLevel: .info,
                              logMessage: "ABC",
                              logDate: "22.01.2001",
                              name: "AbCC",
                              objectType: Log.objectType,
                              objectId: .init(),
                              logTags: ["Tag1", "Tag2"],
                              logLabels: logLabels,
                              logHost: nil)

        let secondObject = Snapshot(creationTimestamp: 1.0,
                                    creatorId: .init(),
                                    object: thirdObject)

        let firstObject = Snapshot(creationTimestamp: 2.0,
                                   creatorId: .init(),
                                   object: secondObject)

        // Initialize the filter object
        // NOTE: It is impossible to create an empty filter with provided intializers, that's why condition and conditions have to be nilled later
        var filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("_"),
                                                                   expression: .exists))
        filter.condition = nil
        filter.conditions = nil

        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: nil)))
        #expect(!(ObjectMatcher.matchesFilter(obj: nil, filter: filter)))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: nil))
        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))

        // Create new filter with 'and' conditions
        let conditions: [ObjectFilterCondition] = [
            // MARK: - Test: .Exists and .NotExists; .Equals and .NotEquals for primitives.
            ObjectFilterCondition(property: ObjectFilterProperty("foo"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("foo.bar"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logHost"),
                                  expression: .notExists),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .equals(true)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .notEquals(false)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notEquals(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .equals("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notEquals("abc")),

            // MARK: - Test: Object nested in Dictionary nested in Object
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.lastProperty"),
                                  expression: .equals(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.nestedObject.logLabels.foo"),
                                  expression: .notExists),

            // MARK: - Test: .Equals and .NotEquals for arrays.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .equals([42, [43, 44], [[45, 46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notEquals([42, [43, 44], [[45, 47]]])),

            // MARK: - Test: .Equals and .NotEquals for objects.
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .equals(FilterOperand(Log(logLevel: .info,
                                                                                                                  logMessage: "ABC",
                                                                                                                  logDate: "22.01.2001",
                                                                                                                  name: "AbCC",
                                                                                                                  objectType: Log.objectType,
                                                                                                                  objectId: thirdObject.objectId,
                                                                                                                  logTags: ["Tag1", "Tag2"],
                                                                                                                  logLabels: logLabels,
                                                                                                                  logHost: nil)))),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .notEquals(FilterOperand(Log(logLevel: .info,
                                                                                                                     logMessage: "...",
                                                                                                                     logDate: "...",
                                                                                                                     name: "...",
                                                                                                                     objectType: Log.objectType,
                                                                                                                     objectId: .init(),
                                                                                                                     logTags: ["Tag1", "Tag2"],
                                                                                                                     logLabels: logLabels,
                                                                                                                     logHost: nil)))),

            // MARK: - TEST: Properties with dot names and properties specified as array
            ObjectFilterCondition(property: ObjectFilterProperty(["object", "object", "logLabels", "nestedObject", "logLabels", ".", ".", "hello"]),
                                  expression: .equals("hello")),

            // MARK: - Test: .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThan(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThan("Abce")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .lessThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .lessThanOrEqual("ABc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThan(41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThan("abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .greaterThanOrEqual(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .greaterThanOrEqual("Abc")),

            // MARK: - Test: .Between
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(42, 42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(41, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .between(43, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abc", "Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abb", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .between("Abd", "Abb")),

            // MARK: - Test: .NotBetween
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(43, 47)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(47, 43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .notBetween(41, 41)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abd", "Abf")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abf", "Abd")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .notBetween("Abb", "Abb")),

            // MARK: - Test: .Like
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Abc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("Ab_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_b_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%__")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%___")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("_%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("__%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("___%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%bc")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("A%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%c")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .like("%%")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString"),
                                  expression: .like("%a_c\\\\d\\_")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString1"),
                                  expression: .like(".*+?^${}()|[]")),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.filterLikeString2"),
                                  expression: .like("\\/")),

            // MARK: - Test: .Contains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains(42)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .contains([42, [43], [[46]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .contains([3, 1, 3, 1])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .contains([3, [3, 2]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .contains(FilterOperand(simpleLog))),

            // MARK: - Test: .NotContains
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains(43)),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array"),
                                  expression: .notContains([41, [45], [[43]]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array1"),
                                  expression: .notContains([3, 1, 5])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.array2"),
                                  expression: .notContains([3, [3, 1]])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.complexLog"),
                                  expression: .notContains(FilterOperand(simpleLog2))),

            // MARK: - Test: .In
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesIn([43, 42, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesIn([43, 42, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesIn([43, true, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        name: "AbCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

            // MARK: - Test: .NotIn
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.number"),
                                  expression: .valuesNotIn([43, 41, "42"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.string"),
                                  expression: .valuesNotIn([43, 42, "abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object.logLabels.boolean"),
                                  expression: .valuesNotIn([43, false, "Abc"])),
            ObjectFilterCondition(property: ObjectFilterProperty("object.object"),
                                  expression: .valuesNotIn([
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "ABC",
                                        logDate: "22.01.2001",
                                        // Only name property is not the same as in object.object
                                        name: "AbCCC",
                                        objectType:
                                        Log.objectType,
                                        objectId: thirdObject.objectId,
                                        logTags: ["Tag1", "Tag2"],
                                        logLabels: logLabels,
                                        logHost: nil)),
                                    FilterOperand(Log(logLevel: .info,
                                        logMessage: "Dummy",
                                        logDate: "2.2.2020"))
                                  ])),

        ]

        filter = ObjectFilter(conditions: ObjectFilterConditions(or: conditions))

        // Edge case
        filter.condition = singleCondition

        #expect(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter))
    }

    @Test

    func testEmptyParametersList() throws {
        let obj = CoatyObject(coreType: .Log,
                              objectType: Log.objectType,
                              objectId: .init(),
                              name: "Hello")

        let filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty(""),
                                                                   expression: .equals("Hello")))

        #expect(!(ObjectMatcher.matchesFilter(obj: obj, filter: filter)))
    }

    @Test

    func testTooShortParametersList() throws {
        let thirdObject = Log(logLevel: .info,
                              logMessage: "ABC",
                              logDate: "22.01.2001",
                              name: "AbCC",
                              objectType: Log.objectType,
                              objectId: .init(),
                              logTags: ["Tag1", "Tag2"])

        let secondObject = Snapshot(creationTimestamp: 1.0,
                                    creatorId: .init(),
                                    object: thirdObject)

        let firstObject = Snapshot(creationTimestamp: 2.0,
                                   creatorId: .init(),
                                   object: secondObject)

        // Shorter list than should be
        let filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("object."),
                                                                   expression: .equals("Hello")))

        #expect(!(ObjectMatcher.matchesFilter(obj: firstObject, filter: filter)))
    }

    @Test

    func testNoConditions() throws {
        let obj = CoatyObject(coreType: .Log,
                              objectType: Log.objectType,
                              objectId: .init(),
                              name: "Hello")

        let filter = ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("name"),
                                                                   expression: .equals("Hello")))

        // Edge case
        filter.condition = nil

        #expect(ObjectMatcher.matchesFilter(obj: obj, filter: filter))

    }

    // MARK: - UUID property filtering across the wire (see issue #102).

    private static let knownUUIDString = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    private static func objectWithKnownId() throws -> CoatyObject {
        return CoatyObject(coreType: .CoatyObject,
                           objectType: "test.Thing",
                           objectId: try #require(CoatyUUID(uuidString: knownUUIDString)),
                           name: "thing")
    }

    private static func objectIdEqualsFilter(operand: FilterOperand) -> ObjectFilter {
        return ObjectFilter(condition: ObjectFilterCondition(property: ObjectFilterProperty("objectId"),
                                                             expression: .equals(operand)))
    }

    @Test

    func testMatchesFilterOnUUIDPropertyBuiltLocally() throws {
        let operand = FilterOperand(CoatyUUID(uuidString: Self.knownUUIDString)!)
        let filter = Self.objectIdEqualsFilter(operand: operand)

        #expect(ObjectMatcher.matchesFilter(obj: try Self.objectWithKnownId(), filter: filter))
    }

    /// A filter that matches locally must still match after crossing the wire.
    ///
    /// Regression test for issue #102: the decoded operand arrives as a
    /// `String` while the object's `objectId` was wrapped as a `CoatyUUID`, so
    /// equality fell through to `default: return false` and the filter
    /// silently never matched.
    @Test

    func testMatchesFilterOnUUIDPropertyAfterWireRoundTrip() throws {
        let operand = FilterOperand(CoatyUUID(uuidString: Self.knownUUIDString)!)
        let filter = Self.objectIdEqualsFilter(operand: operand)

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ObjectFilter.self, from: data)

        #expect(ObjectMatcher.matchesFilter(obj: try Self.objectWithKnownId(), filter: decoded))
    }

    /// A CoatyJS peer authors the operand as a plain JSON string. That must
    /// match an Axoloty object whose `objectId` is a `CoatyUUID`.
    @Test

    func testMatchesFilterOnUUIDPropertyWithStringOperand() throws {
        let filter = Self.objectIdEqualsFilter(operand: FilterOperand(Self.knownUUIDString))

        #expect(ObjectMatcher.matchesFilter(obj: try Self.objectWithKnownId(), filter: filter))
    }
}
