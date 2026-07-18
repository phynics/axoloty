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
///
/// This type is `@unchecked Sendable` because it is stored in
/// ``JSONDecoder/userInfo`` as an `(any Sendable)` value. Its mutable state is
/// only accessed synchronously during one decode operation; ``JSONDecoder``
/// does not invoke a decoder concurrently, and this stack is never shared with
/// another decode operation.
final class DecodingContextStack: @unchecked Sendable {
    private var items: [(any Sendable)?] = []

    /// Push the given context data for recursive decoding.
    func push(_ context: (any Sendable)?) {
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
    var current: (any Sendable)? {
        guard let last = items.last else {
            return nil
        }
        return last
    }
}

extension Decoder {

    /// Gets context data stored in the decoder's user info for a key.
    ///
    /// - Parameter key: The key identifying the context data.
    /// - Returns: The context data, or `nil` when no value is stored for `key`.
    func getContext(forKey key: String) -> Any? {
        let infoKey = CodingUserInfoKey(rawValue: key)!
        return userInfo[infoKey]
    }

    /// Pushes `Sendable` context data for recursive decoding.
    ///
    /// - Parameters:
    ///   - context: The context data to push.
    ///   - key: The key identifying the recursive context stack.
    func pushContext(_ context: (any Sendable)?, forKey key: String) {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return
        }
        contextStack.push(context)
    }

    /// Pops the latest context data for recursive decoding.
    ///
    /// - Parameter key: The key identifying the recursive context stack.
    func popContext(forKey key: String) {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return
        }
        contextStack.pop()
    }

    /// Gets the latest `Sendable` context data for recursive decoding.
    ///
    /// - Parameter key: The key identifying the recursive context stack.
    /// - Returns: The latest context data, or `nil` when no context is
    ///   available.
    func currentContext(forKey key: String) -> (any Sendable)? {
        guard let contextStack = getContext(forKey: key) as? DecodingContextStack else {
            return nil
        }
        return contextStack.current
    }

    /// Pushes `Sendable` context data, executes an action, then pops the context.
    ///
    /// - Parameters:
    ///   - context: The context data to push.
    ///   - key: The key identifying the recursive context stack.
    ///   - action: The operation to perform while the context is current.
    /// - Returns: The value returned by `action`.
    func withContext<T>(_ context: (any Sendable)?, forKey key: String, action: () throws -> T) rethrows -> T {
        pushContext(context, forKey: key)
        defer {
            popContext(forKey: key)
        }
        return try action()
    }

}

extension JSONDecoder {

    /// Sets `Sendable` context data accessible in the decoder's user info.
    ///
    /// - Parameters:
    ///   - context: The context data to store.
    ///   - key: The key identifying the context data.
    func setContext(_ context: (any Sendable)?, forKey key: String) {
        let infoKey = CodingUserInfoKey(rawValue: key)!
        userInfo[infoKey] = context
    }

    /// Sets up a recursive decoding context stack.
    ///
    /// - Parameter key: The key identifying the recursive context stack.
    func initPushContext(forKey key: String) {
        setContext(DecodingContextStack(), forKey: key)
    }

}
