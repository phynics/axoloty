// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

@Suite
struct ObjectTypeRegistryTests {
    private final class RegisteredTypeA: CoatyObject {}
    private final class RegisteredTypeB: CoatyObject {}

    @Test

    func testConcurrentRegistrationAndLookupRemainConsistent() {
        let iterations = 1_000
        let failures = LockedArray<String>()

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let objectType = "test.concurrent.type.\(index)"
            let expectedType: CoatyObject.Type = index.isMultiple(of: 2)
                ? RegisteredTypeA.self
                : RegisteredTypeB.self
            _ = CoatyObject.register(objectType: objectType, with: expectedType)

            guard let actualType = CoatyObject.getClassType(forObjectType: objectType),
                  ObjectIdentifier(actualType) == ObjectIdentifier(expectedType) else {
                failures.append(objectType)
                return
            }

            let object = CoatyObject(
                coreType: .CoatyObject,
                objectType: objectType,
                objectId: CoatyUUID(),
                name: "registered"
            )
            if !object.isObjectTypeRegistered {
                failures.append(objectType)
            }
        }

        #expect(failures.values == [])
    }

    @Test

    func testUnregisteredObjectTypeIsReportedAsUnregistered() {
        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "test.unregistered.\(CoatyUUID().string)",
            objectId: CoatyUUID(),
            name: "unregistered"
        )

        #expect(!(object.isObjectTypeRegistered))
    }
}

private final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var array: [T] = []

    func append(_ element: T) {
        lock.withLock { array.append(element) }
    }

    var values: [T] { lock.withLock { array } }
}
