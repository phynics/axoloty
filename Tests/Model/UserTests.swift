// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  UserTests.swift
//  Axoloty

import Foundation
import Testing
import Axoloty

/// Regression tests for the SCIM 2 `User` model.
///
/// Issue #445 / P1-1: `User.encode(to:)` wrote each optional property under
/// the wrong coding key (e.g. `userType` under `.title`, `active` under
/// `.timezone`). That made `encode` round-trip into a `User` with the wrong
/// fields populated and, on the wire, produced key names that did not match
/// the SCIM RFC 7643 schema that `init(from:)` reads.
@Suite
struct UserTests {

    private func makeFullyPopulatedUser() -> User {
        let user = User(
            name: "bjensen",
            names: ScimUserNames(
                formatted: "Babs Jensen",
                familyName: "Jensen",
                givenName: "Babs"
            ),
            objectType: "User",
            objectId: CoatyUUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        user.displayName = "Babs Jensen"
        user.nickName = "Babs"
        user.title = "Vice President"
        user.userType = "Employee"
        user.preferredLanguage = "en-US"
        user.locale = "en-US"
        user.timezone = "America/Los_Angeles"
        user.active = true
        user.password = "s3cret"
        user.emails = [
            ScimMultiValuedAttribute(type: "work", value: "bjensen@example.com", primary: true)
        ]
        user.phoneNumbers = [
            ScimMultiValuedAttribute(type: "work", value: "555-555-5555")
        ]
        user.ims = [
            ScimMultiValuedAttribute(type: "xmpp", value: "@bjensen")
        ]
        user.photos = [
            ScimMultiValuedAttribute(type: "photo", value: "https://example.com/photo.png")
        ]
        user.addresses = nil
        user.groups = [
            ScimMultiValuedAttribute(type: "direct", value: "engineering")
        ]
        user.entitlements = "[\"admin\"]"
        user.roles = ["manager"]
        user.x509Certificates = ["MiAGAf=="]
        return user
    }

    /// Encode must emit each SCIM field under its own canonical RFC 7643 key,
    /// not under a neighboring field's key. This is the wire-visible assertion
    /// behind P1-1.
    @Test
    func encodeUsesCorrectScimCodingKeys() throws {
        let user = makeFullyPopulatedUser()
        let data = try JSONEncoder().encode(user)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["userType"] as? String == "Employee")
        #expect(json["locale"] as? String == "en-US")
        #expect(json["preferredLanguage"] as? String == "en-US")
        #expect(json["active"] as? Bool == true)
        #expect(json["password"] as? String == "s3cret")
        #expect(json["nickName"] as? String == "Babs")
        #expect(json["displayName"] as? String == "Babs Jensen")
        #expect(json["title"] as? String == "Vice President")
        #expect(json["timezone"] as? String == "America/Los_Angeles")
        #expect(json["x509Certificates"] != nil)
        // `entitlements` is stored as raw JSON text; it encodes as the parsed
        // JSON array, so it reads back as an array.
        #expect((json["entitlements"] as? [String]) == ["admin"])
        #expect(json["roles"] != nil)
        #expect(json["emails"] != nil)
        #expect(json["ims"] != nil)
        #expect(json["groups"] != nil)
    }

    /// A full encode → decode round trip must reproduce every field. On the
    /// buggy `main`, `userType` was written under `.title` and re-read under
    /// `.userType`, so `userType` came back nil and `title` absorbed it.
    @Test
    func encodeDecodeRoundTripPreservesAllFields() throws {
        let original = makeFullyPopulatedUser()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(User.self, from: data)

        #expect(decoded.objectId == original.objectId)
        #expect(decoded.name == original.name)
        #expect(decoded.names.formatted == original.names.formatted)
        #expect(decoded.names.givenName == original.names.givenName)
        #expect(decoded.names.familyName == original.names.familyName)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.nickName == original.nickName)
        #expect(decoded.title == original.title)
        #expect(decoded.userType == original.userType)
        #expect(decoded.preferredLanguage == original.preferredLanguage)
        #expect(decoded.locale == original.locale)
        #expect(decoded.timezone == original.timezone)
        #expect(decoded.active == original.active)
        #expect(decoded.password == original.password)
        #expect(decoded.roles == original.roles)
        #expect(decoded.x509Certificates == original.x509Certificates)
        #expect(decoded.entitlements == original.entitlements)
        #expect(decoded.phoneNumbers?.count == original.phoneNumbers?.count)
        #expect(decoded.ims?.count == original.ims?.count)
        #expect(decoded.emails?.count == original.emails?.count)
        #expect(decoded.groups?.count == original.groups?.count)
        #expect(decoded.photos?.count == original.photos?.count)
    }
}