//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  Decoder+Context.swift
//  Axoloty
//
//

import Foundation

/// Reference-type stack used to share mutable decoding context state across
/// recursive/nested decoder invocations.
///
/// `Decoder.userInfo` is a value-typed `[CodingUserInfoKey: Any]` dictionary,
/// but nested decoders/containers created while decoding a class hierarchy
/// are handed copies of it. Storing a class instance as the dictionary value
/// (rather than a plain Swift `Array`) means every copy of the dictionary
/// still refers to the very same stack, so pushes/pops made at one level of
/// a decode are visible to callers at other levels.
final class DecodingContextStack {
    private var items: [Any?] = []

    /// Push the given context data for recursive decoding.
    func push(_ context: Any?) {
        items.append(context)
    }

    /// Pop the latest context data for recursive decoding.
    func pop() {
        guard !items.isEmpty else {
            return
        }
        items.removeLast()
    }

    /// The latest context data for recursive decoding.
    var current: Any? {
        guard let last = items.last else {
            return nil
        }
        return last
    }
}

extension Decoder {

    /// Get context data stored on decoder's user info indexed by the given key.
    func getContext(forKey key: String) -> Any? {
        let infoKey = CodingUserInfoKey(rawValue: key)!
        return userInfo[infoKey]
    }

    /// Push the given context data for recursive decoding.
    func pushContext(_ context: Any?, forKey key: String) {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return
        }
        contextStack.push(context)
    }

    /// Pop the latest context data for recursive decoding.
    func popContext(forKey key: String) {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return
        }
        contextStack.pop()
    }

    /// Get the latest context data for recursive decoding.
    func currentContext(forKey key: String) -> Any? {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return nil
        }
        return contextStack.current
    }

    /// Push the given context data for recursive decoding, execute the given action and pop the pushed context.
    func withContext<T>(_ context: Any?, forKey key: String, action: () throws -> T) rethrows -> T {
        pushContext(context, forKey: key)
        defer {
            popContext(forKey: key)
        }
        return try action()
    }

}

extension JSONDecoder {

    /// Set context data to be accessible on decoder's user info indexed by the given key.
    ///
    /// - Note: The compiler warns "type 'Any' does not conform to the 'Sendable'
    ///   protocol" on the `userInfo[infoKey] = context` assignment below. This
    ///   is left intentionally: the only value stored in practice is a
    ///   ``DecodingContextStack`` (via ``initPushContext(forKey:)``), and
    ///   silencing the diagnostic requires changing the public `Any?` parameter
    ///   to `(any Sendable)?` across this extension and ``DecodingContextStack``
    ///   — a breaking public API change that needs an approved plan. Making
    ///   ``DecodingContextStack`` itself `@unchecked Sendable` does *not* help
    ///   (the warning is on the `Any` type, not the concrete value).
    func setContext(_ context: Any?, forKey key: String) {
        let infoKey = CodingUserInfoKey(rawValue: key)!
        userInfo[infoKey] = context
    }

    /// Set up context data for recursive decoding.
    func initPushContext(forKey key: String) {
        setContext(DecodingContextStack(), forKey: key)
    }

}
