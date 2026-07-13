//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  MutableBox.swift
//  Axoloty
//
//

import Foundation

/// A reference-type (class) wrapper around a Swift `Array`, giving it
/// reference rather than value semantics.
///
/// Some call sites in this codebase fetch a nested collection out of an
/// outer, keyed collection via subscript and then mutate the fetched value
/// in place (append/remove elements), relying on the mutation being visible
/// through the outer collection *without* writing the mutated value back.
/// That pattern only works if the fetched value is a reference type -
/// native Swift `Array`/`Dictionary` are value types (copy-on-write), so
/// fetching one out of a dictionary yields an independent copy and silently
/// drops in-place mutations. This box exists to keep that reliance on
/// reference semantics explicit and type-safe instead of falling back to
/// `NSMutableArray`.
///
/// - Note: `swift-collections` was considered as an alternative, but all of
///   its collection types (`Deque`, `OrderedSet`, `OrderedDictionary`, etc.)
///   are value types with copy-on-write semantics, just like the standard
///   library's `Array`/`Dictionary` - they don't provide reference
///   semantics either, so they don't solve this particular problem.
final class MutableArrayBox<Element> {

    private(set) var storage: [Element]

    init(_ storage: [Element] = []) {
        self.storage = storage
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    subscript(index: Int) -> Element {
        storage[index]
    }

    func append(_ element: Element) {
        storage.append(element)
    }

    func remove(at index: Int) {
        storage.remove(at: index)
    }

    func first(where predicate: (Element) -> Bool) -> Element? {
        storage.first(where: predicate)
    }

    func forEach(_ body: (Element) -> Void) {
        storage.forEach(body)
    }
}

extension MutableArrayBox where Element: Equatable {

    func contains(_ element: Element) -> Bool {
        storage.contains(element)
    }

    func remove(_ element: Element) {
        if let index = storage.firstIndex(of: element) {
            storage.remove(at: index)
        }
    }
}

/// A reference-type (class) wrapper around a Swift `Dictionary`, giving it
/// reference rather than value semantics.
///
/// See `MutableArrayBox` above for the rationale: call sites fetch this
/// nested map out of an outer, keyed collection via subscript and mutate it
/// in place (insert/update/remove entries) across several steps, expecting
/// the outer collection to see the accumulated mutations without an
/// explicit write-back. That requires the fetched value to be a reference
/// type.
final class MutableDictionaryBox<Key: Hashable, Value> {

    private(set) var storage: [Key: Value]

    init(_ storage: [Key: Value] = [:]) {
        self.storage = storage
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    func removeValue(forKey key: Key) {
        storage.removeValue(forKey: key)
    }

    func forEach(_ body: (Key, Value) -> Void) {
        storage.forEach(body)
    }
}
