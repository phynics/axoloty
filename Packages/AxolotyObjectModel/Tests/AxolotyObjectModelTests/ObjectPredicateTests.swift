import Testing
import AxolotyWire
@testable import AxolotyObjectModel

private func predicateSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

private func predicateObject(_ value: StaticString) throws -> BoundedDynamicObject<512, 8> {
    try BoundedDynamicObject<512, 8>(decoding: predicateSlice(value))
}

@Test func everyCoatyOperatorCodeDecodesAndMatches() throws {
    let cases: [(StaticString, Bool)] = [
        ("{\"conditions\":[[\"v\",[0,2]]]}" , true),
        ("{\"conditions\":[[\"v\",[1,2]]]}" , true),
        ("{\"conditions\":[[\"v\",[2,2]]]}" , false),
        ("{\"conditions\":[[\"v\",[3,2]]]}" , false),
        ("{\"conditions\":[[\"v\",[4,2,3]]]}" , true),
        ("{\"conditions\":[[\"v\",[5,2,3]]]}" , false),
        ("{\"conditions\":[[\"v\",[6,\"2\"]]]}", false),
        ("{\"conditions\":[[\"v\",[7,2]]]}" , true),
        ("{\"conditions\":[[\"v\",[8,3]]]}" , true),
        ("{\"conditions\":[[\"v\",[9]]]}" , true),
        ("{\"conditions\":[[\"missing\",[10]]]}" , true),
        ("{\"conditions\":[[\"v\",[11,2]]]}" , true),
        ("{\"conditions\":[[\"v\",[12,3]]]}" , true),
        ("{\"conditions\":[[\"v\",[13,[1,2]]]]}" , true),
        ("{\"conditions\":[[\"v\",[14,[1,3]]]]}" , true),
    ]
    for (filter, expected) in cases {
        let predicate = try ObjectPredicate<64, 8, 8, 512>(decoding: predicateSlice(filter))
        let object = try predicateObject("{\"v\":2}")
        #expect(predicate.matches(object: object) == expected)
    }
}

@Test func nestedGroupsPathsAndEscapedKeysMatch() throws {
    let filter = predicateSlice("{\"conditions\":{\"or\":[[\"nested.value\",[7,2]],[[\"a.b\"],[7,3]] ]}}")
    let predicate = try ObjectPredicate<128, 16, 8, 512>(decoding: filter)
    let object = try predicateObject("{\"nested\":{\"value\":2},\"a.b\":3}")
    #expect(predicate.matches(object: object))
}

@Test func exactDecimalsAndNegativeZeroCompareWithoutDouble() throws {
    let equality = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[[\"value\",[7,1.0]]]}"))
    let zero = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[[\"value\",[7,-0.0]]]}"))
    let object = try predicateObject("{\"value\":1e0}")
    #expect(equality.matches(object: object))
    #expect(zero.matches(object: object) == false)
}

@Test func containsAndMembershipAreRecursiveAndOrderIndependent() throws {
    let contains = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[[\"value\",[11,{\"b\":[2],\"a\":1}]]]}"))
    let membership = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[[\"value\",[13,[{\"a\":1,\"b\":[2]}]]]]}"))
    let object = try predicateObject("{\"value\":{\"a\":1,\"b\":[2,3],\"extra\":true}}")
    #expect(contains.matches(object: object))
    #expect(membership.matches(object: object))
}

@Test func likeUsesPercentUnderscoreAndEscapes() throws {
    let like = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[[\"name\",[6,\"a_%\"]]]}"))
    let object = try predicateObject("{\"name\":\"abc\"}")
    #expect(like.matches(object: object))

    // The JSON `\\\\%` spelling decodes to a LIKE escape plus a literal `%`.
    let escaped = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[[\"name\",[6,\"a\\\\%b\"]]]}"))
    let escapedObject = try predicateObject("{\"name\":\"a%b\"}")
    #expect(escaped.matches(object: escapedObject))
}

@Test func failedAppendConditionIsAtomic() throws {
    var predicate = try ObjectPredicate<4, 2, 2, 16>(path: "value", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) {
        try predicate.appendCondition(path: "a", expression: .equals(.string("this value cannot fit")))
    }
    let object = try predicateObject("{\"value\":1,\"a\":\"this value cannot fit\"}")
    #expect(predicate.matches(object: object))
}
