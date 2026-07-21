// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import IkigaJSON

/// Carries the parsed payload tree through a decoding operation.
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
