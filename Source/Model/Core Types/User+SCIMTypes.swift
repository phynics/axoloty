//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  User+SCIMTypes.swift
//  Axoloty
//
//

import Foundation

/// The components of the SCIM user's name.
/// Service providers MAY return
/// just the full name as a single string in the formatted
/// sub-attribute, or they MAY return just the individual component
/// attributes using the other sub-attributes, or they MAY return
/// both. If both variants are returned, they SHOULD be describing
/// the same name, with the formatted name indicating how the
/// component attributes should be combined.
public class ScimUserNames: Codable {

    /// The full name, including all middle names, titles, and
    /// suffixes as appropriate, formatted for display (e.g.,
    /// "Ms. Barbara Jane Jensen, III").
    public var formatted: String?

    /// The family name of the User, or last name in most
    /// Western languages (e.g., "Jensen" given the full name
    /// "Ms. Barbara Jane Jensen, III").
    public var familyName: String?

    /// The given name of the User, or first name in most
    /// Western languages (e.g., "Barbara" given the full name
    /// "Ms. Barbara Jane Jensen, III").
    public var givenName: String?

    /// The middle name(s) of the User (e.g., "Jane" given the
    /// full name "Ms. Barbara Jane Jensen, III").
    public var middleName: String?

    /// The honorific prefix(es) of the User, or title in
    /// most Western languages (e.g., "Ms." given the full name
    /// Ms. Barbara Jane Jensen, III").
    public var honorificPrefix: String?

    /// The honorific suffix(es) of the User, or suffix
    /// in most Western languages (e.g., "III" given the full name
    /// "Ms. Barbara Jane Jensen, III").
    public var honorificSuffix: String?

    public init(
        formatted: String? = nil,
        familyName: String? = nil,
        givenName: String? = nil,
        middleName: String? = nil,
        honorificPrefix: String? = nil,
        honorificSuffix: String? = nil
    ) {
        self.formatted = formatted
        self.familyName = familyName
        self.givenName = givenName
        self.middleName = middleName
        self.honorificPrefix = honorificPrefix
        self.honorificSuffix = honorificSuffix
    }
}

public class ScimMultiValuedAttribute: Codable {

    // MARK: Attributes.

    /// A label indicating the attribute's function, e.g., "work" or
    /// "home".
    public var type: String

    /// The attribute's significant value, e.g., email address,
    /// phone number.
    public var value: String

    /// A Boolean value indicating the 'primary' or preferred attribute
    /// value for this attribute, e.g., the preferred mailing address or
    /// the primary email address. The primary attribute value "true"
    /// MUST appear no more than once. If not specified, the value of
    /// "primary" SHALL be assumed to be "false".
    public var primary: Bool?

    /// A human-readable name, primarily used for display purposes and
    /// having a mutability of "immutable".
    public var display: String?

    // MARK: Initializers.

    public init(type: String, value: String, primary: Bool? = nil, display: String? = nil) {
        self.type = type
        self.value = value
        self.primary = primary
        self.display = display
    }

    // MARK: - Codable methods.

    enum ScimMultiValuedAttributeKeys: String, CodingKey {
        case type
        case value
        case primary
        case display
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ScimMultiValuedAttributeKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.value = try container.decode(String.self, forKey: .value)
        self.primary = try container.decodeIfPresent(Bool.self, forKey: .primary)
        self.display = try container.decodeIfPresent(String.self, forKey: .display)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ScimMultiValuedAttributeKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(primary, forKey: .primary)
        try container.encodeIfPresent(display, forKey: .display)
    }
}
