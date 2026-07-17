//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  PayloadCoder.swift
//  Axoloty
//
//

import ErrorKit
import Foundation

/// PayloadCoder provides utility methods to encode and decode communication events from and to JSON.
public class PayloadCoder {

    /// Decodes a communication event from its JSON representation.
    ///
    /// - NOTE: The JSON decoding is based on the Codable protocol from the Swift standard library.
    /// Please make sure to implement it in all CommunicationEvent and CoatyObject classes.
    ///
    /// - Throws: ``AxolotyError/decodingFailure(type:reason:payload:)`` if the
    ///   JSON cannot be decoded into the requested type.
    public static func decode<T: Codable>(_ jsonString: String) throws -> T {
        // `String.data(using: .utf8)` cannot fail for a Swift `String` --
        // Swift strings are always representable in UTF-8.
        let jsonData = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.initPushContext(forKey: "coreTypeKeys")
        do {
            return try decoder.decode(T.self, from: jsonData)
        } catch {
            throw AxolotyError.decodingFailure(
                type: String(describing: T.self),
                reason: ErrorKit.userFriendlyMessage(for: error),
                payload: jsonString
            )
        }
    }

    /// Encodes a communication event to its JSON representation.
    ///
    /// - NOTE: The JSON encoding is based on the Codable protocol from the Swift standard library.
    /// Please make sure to implement it in all CommunicationEvent and CoatyObject classes.
    ///
    /// - Throws: ``AxolotyError/caught(_:)`` if the value contains data ``JSONEncoder``
    ///   cannot represent (e.g. a ``Double`` holding `NaN`/`infinity` set by
    ///   downstream application code).
    public static func encode<T: Codable>(_ event: T) throws -> String {
        do {
            let jsonData = try JSONEncoder().encode(event)
            // JSON produced by `JSONEncoder` is always valid UTF-8 by spec.
            return String(data: jsonData, encoding: .utf8)!
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    /// Encodes a value to JSON and returns `"{}"` if encoding fails.
    ///
    /// Used by non-throwing convenience properties (`CommunicationEvent.json`,
    /// `CoatyObject.json`) that are read from publish call sites that do not
    /// otherwise throw. The failure is logged at `.error` with the full cause
    /// chain.
    internal static func encodeForJSON<T: Codable>(_ value: T) -> String {
        do {
            return try encode(value)
        } catch {
            LogManager.logger(.communication).error("Failed to encode value to JSON", metadata: [
                "type": .string("\(T.self)"),
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
            return "{}"
        }
    }
}
