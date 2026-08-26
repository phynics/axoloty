// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import AxolotyObjectModel

extension ObjectPredicateTests {
@Test func everyCoatyOperatorCodeDecodesAndMatches() throws {
    let cases: [(StaticString, Bool)] = [
        ("{\"conditions\":[\"v\",[0,2]]}" , false), ("{\"conditions\":[\"v\",[1,2]]}" , true),
        ("{\"conditions\":[\"v\",[2,2]]}" , false), ("{\"conditions\":[\"v\",[3,2]]}" , true),
        ("{\"conditions\":[\"v\",[4,2,3]]}" , true), ("{\"conditions\":[\"v\",[5,2,3]]}" , false),
        ("{\"conditions\":[\"v\",[6,\"2\"]]}", false), ("{\"conditions\":[\"v\",[7,2]]}" , true),
        ("{\"conditions\":[\"v\",[8,3]]}" , true), ("{\"conditions\":[\"v\",[9]]}" , true),
        ("{\"conditions\":[\"missing\",[10]]}" , true), ("{\"conditions\":[\"v\",[11,2]]}" , true),
        ("{\"conditions\":[\"v\",[12,3]]}" , true), ("{\"conditions\":[\"v\",[13,[1,2]]]}" , true),
        ("{\"conditions\":[\"v\",[14,[1,3]]]}" , true),
    ]
    for (filter, expected) in cases {
        let predicate = try ObjectPredicate<64, 8, 8, 512>(decoding: predicateSlice(filter))
        let object = try predicateObject("{\"v\":2}")
        let matched = predicate.matches(object: object)
        #expect(matched == expected)
    }
}

@Test func nestedGroupsPathsAndEscapedKeysMatch() throws {
    let filter = predicateSlice("{\"conditions\":{\"or\":[[\"nested.value\",[7,2]],[[\"a.b\"],[7,3]] ]}}")
    let predicate = try ObjectPredicate<128, 16, 8, 512>(decoding: filter)
    let object = try predicateObject("{\"nested\":{\"value\":2},\"a.b\":3}")
    let matched = predicate.matches(object: object)
    #expect(matched)
}

@Test func directConditionAndConditionSetShapesMatchCoatyWire() throws {
    let direct = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[7,2]]}"))
    let grouped = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice("{\"conditions\":{\"and\":[[\"v\",[7,2]],[\"present\",[9]]]}}"))
    let object = try predicateObject("{\"v\":2,\"present\":null}")
    let directMatched = direct.matches(object: object)
    let groupedMatched = grouped.matches(object: object)
    #expect(directMatched)
    #expect(groupedMatched)
}

@Test func containsAndMembershipAreRecursiveAndOrderIndependent() throws {
    let contains = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[\"value\",[11,{\"b\":[2],\"a\":1}]]}"))
    let membership = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[\"value\",[13,[{\"a\":1,\"b\":[2]}]]]}"))
    let object = try predicateObject("{\"value\":{\"a\":1,\"b\":[2,3],\"extra\":true}}")
    let membershipObject = try predicateObject("{\"value\":{\"a\":1,\"b\":[2]}}")
    let containsMatched = contains.matches(object: object)
    let membershipMatched = membership.matches(object: membershipObject)
    #expect(containsMatched)
    #expect(membershipMatched)
}

@Test func likeUsesPercentUnderscoreAndEscapes() throws {
    let like = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"name\",[6,\"a_%\"]]}"))
    let object = try predicateObject("{\"name\":\"abc\"}")
    let likeMatched = like.matches(object: object)
    #expect(likeMatched)
    let escaped = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"name\",[6,\"a\\\\%b\"]]}"))
    let escapedObject = try predicateObject("{\"name\":\"a%b\"}")
    let escapedMatched = escaped.matches(object: escapedObject)
    #expect(escapedMatched)
}

@Test func absentConditionsRetainsCoatyMatchAllSemantics() throws {
    let predicate = try ObjectPredicate<16, 2, 2, 64>(decoding: predicateSlice("{}"))
    let object = try predicateObject("{\"unfiltered\":true}")
    let matched = predicate.matches(object: object)
    #expect(matched)
}
}
