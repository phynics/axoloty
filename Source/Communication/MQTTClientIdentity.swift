// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum MQTTClientIdentity {
    static func make(for identity: Identity) -> String {
        let compactId = identity.objectId.string.replacingOccurrences(of: "-", with: "")
        let clientName = normalizedName(identity.name)

        guard !clientName.isEmpty else {
            return "Coaty" + String(compactId.prefix(18))
        }

        let uniqueSuffix = String(compactId.prefix(12)) + String(compactId.dropFirst(13).prefix(1))
        return String(clientName.prefix(10)) + uniqueSuffix
    }

    private static func normalizedName(_ name: String) -> String {
        var normalized = ""
        var capitalizeNext = false

        for scalar in name.unicodeScalars {
            let value = scalar.value
            let isDigit = (48...57).contains(value)
            let isUppercase = (65...90).contains(value)
            let isLowercase = (97...122).contains(value)

            guard isDigit || isUppercase || isLowercase else {
                capitalizeNext = !normalized.isEmpty
                continue
            }

            let character = Character(String(scalar))
            if capitalizeNext && isLowercase {
                normalized.append(contentsOf: String(character).uppercased())
            } else {
                normalized.append(character)
            }
            capitalizeNext = false
        }

        return normalized
    }
}
