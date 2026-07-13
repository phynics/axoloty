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
        let failureLock = NSLock()
        var failures = [String]()

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let objectType = "test.concurrent.type.\(index)"
            let expectedType: CoatyObject.Type = index.isMultiple(of: 2)
                ? RegisteredTypeA.self
                : RegisteredTypeB.self
            _ = CoatyObject.register(objectType: objectType, with: expectedType)

            guard let actualType = CoatyObject.getClassType(forObjectType: objectType),
                  ObjectIdentifier(actualType) == ObjectIdentifier(expectedType) else {
                failureLock.lock()
                failures.append(objectType)
                failureLock.unlock()
                return
            }

            let object = CoatyObject(
                coreType: .CoatyObject,
                objectType: objectType,
                objectId: CoatyUUID(),
                name: "registered"
            )
            if !object.isObjectTypeRegistered {
                failureLock.lock()
                failures.append(objectType)
                failureLock.unlock()
            }
        }

        #expect((failures) == ([]))
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
