// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import IkigaJSON

/// Carries the parsed payload tree through a decoding operation.
///
/// This type is `@unchecked Sendable` only because decoder context values are
/// stored in `Sendable` user information. A context is created for one decode
/// operation, and its mutable `currentObject` is accessed only synchronously
/// by that operation; no context instance is shared by concurrent decodes.
final class RawJSONObjectContext: @unchecked Sendable {
    let root: JSONObject
    private var currentObject: JSONObject?

    init(root: JSONObject) {
        self.root = root
        self.currentObject = nil
    }

    func setCurrentObject(_ object: JSONObject?) {
        currentObject = object
    }

    var decodedObject: JSONObject? {
        currentObject
    }

    func object(at path: [any CodingKey]) -> JSONObject? {
        var current: (any IkigaJSON.JSONValue)? = root
        for key in path {
            if let object = current?.object {
                current = object[key.stringValue]
            } else if let array = current?.array, let index = key.intValue, index >= 0, index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current?.object
    }
}
