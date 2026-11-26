// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyObservedObjects
import AxolotyWire

struct Gauge: ObjectSchema {
    let reading: Int

    static let schema: PortableObjectSchema<Gauge> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("reading")!, index: 0, flags: .required)
        return PortableObjectSchema(
            objectType: ObjectType("Gauge")!, coreType: .coatyObject,
            fieldCount: 1, fields: fields
        )
    }()

    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        reading = try fields.decode("reading", as: Int.self)
    }

    borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        do {
            try encoder.setInteger(reading, forKey: "reading")
        } catch {
            throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

let uuid = UUID16(parsing: "11111111-1111-4111-8111-111111111111")!
let gauge = ObjectID(uuid: uuid)
let correlation = UUID16(parsing: "22222222-2222-4222-8222-222222222222")!
let profile = WireProfile.coaty3JSON
let policy = try ObjectViewConfiguration(staleAfterTicks: 10, retainForTicks: 20)
var view = try ObjectView(watching: [gauge], configuration: policy, profile: profile)
let session = view.beginSession()
let interest = try ReconciliationInterest(objectID: gauge, timeoutMS: 1_000)
let request = try interest.request(correlationID: correlation, profile: profile)
guard case .discover = request else { fatalError("expected Discover") }

// A captured Resolve lets this example run without a broker. In a live caller,
// submit request explicitly and check the runtime epoch before admitting a reply.
let payload = #"{"object":{"objectId":"11111111-1111-4111-8111-111111111111","objectType":"Gauge","coreType":"CoatyObject","name":"Pump","reading":42,"vendorNote":"kept"}}"#
let reply = RuntimeEventValue(
    family: .resolve,
    context: RuntimeEventContext(sourceID: .zero, correlationID: correlation, namespace: "demo", receiptTimeMS: 100),
    value: Array(payload.utf8)
)
guard let observation = try interest.observation(from: reply, correlationID: correlation, profile: profile) else {
    fatalError("expected the matching gauge observation")
}
try view.apply(observation, in: session, observedAt: 100)

let snapshot = view.snapshot(for: gauge, at: 101)
guard case .observed(let candidate) = snapshot.evidence else { fatalError("expected gauge evidence") }
let reading = try candidate.decode(Gauge.self).reading
let stale = view.snapshot(for: gauge, at: 110).freshness
precondition(reading == 42 && stale == .stale)
print("Gauge reading \(reading) is \(stale) at tick 110.")
