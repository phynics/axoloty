// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  ObjectJoinConditionTests.swift
//  Axoloty

import Foundation
import Testing
import Axoloty

@Suite
struct ObjectJoinConditionTests {

    @Test
    func exposesCompleteConditionState() {
        let condition = ObjectJoinCondition(
            localProperty: "parentId",
            asProperty: "children",
            isLocalPropertyArray: true,
            isOneToOneRelation: false
        )

        #expect(condition.localProperty == "parentId")
        #expect(condition.asProperty == "children")
        #expect(condition.isLocalPropertyArray == true)
        #expect(condition.isOneToOneRelation == false)
    }

    @Test
    func jsonRoundTripPreservesStateAndCodingKeys() throws {
        let condition = ObjectJoinCondition(
            localProperty: "parentId",
            asProperty: "children",
            isLocalPropertyArray: true,
            isOneToOneRelation: false
        )
        let encoded = try JSONEncoder().encode(condition)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(json.keys) == [
            "localProperty",
            "asProperty",
            "isLocalPropertyArray",
            "isOneToOneRelation",
        ])
        #expect(json["localProperty"] as? String == "parentId")
        #expect(json["asProperty"] as? String == "children")
        #expect(json["isLocalPropertyArray"] as? Bool == true)
        #expect(json["isOneToOneRelation"] as? Bool == false)

        let decoded = try JSONDecoder().decode(ObjectJoinCondition.self, from: encoded)
        #expect(decoded.localProperty == condition.localProperty)
        #expect(decoded.asProperty == condition.asProperty)
        #expect(decoded.isLocalPropertyArray == condition.isLocalPropertyArray)
        #expect(decoded.isOneToOneRelation == condition.isOneToOneRelation)
    }
}
