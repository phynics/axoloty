// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotySensorThingsModel
import AxolotyWire

/// The Thing-and-Sensor catalogue state machine, with no runtime attached.
///
/// The registry previously interleaved three concerns in one actor method:
/// decoding a runtime event, deciding what the catalogue should become, and
/// publishing the result to a stream. Only the middle one is policy, and it
/// is the part worth testing directly -- capacity refusal, deduplication by
/// encoded bytes, parent-relationship checks, and the ordering guarantee that
/// each removal reports the complete remaining catalogue.
///
/// This type owns that decision and nothing else. It is a value, synchronous,
/// and unaware of streams, diagnostics, and events; the registry actor
/// translates its outcomes into both.
struct SensorThingsCatalogue: Sendable {
    /// What applying an object did to the catalogue.
    enum Outcome: Sendable {
        /// Nothing changed: not ours, unchanged bytes, or a failed
        /// relationship check.
        case ignored
        /// The Sensor was refused because the catalogue is full.
        case capacityExceeded
        /// The catalogue changed. Each transition is reported in order.
        case changed([Transition])
    }

    /// One catalogue transition, before it becomes a published change.
    struct Transition: Sendable {
        let kind: SensorThingsCatalogueChangeKind
        let sensor: SensorThingsObjectSnapshot<Sensor>?
        let thing: SensorThingsObjectSnapshot<Thing>?
    }

    private let thingID: ObjectID
    private let maximumSensors: Int
    private(set) var thing: SensorThingsObjectSnapshot<Thing>?
    private var sensors: [ObjectID: SensorThingsObjectSnapshot<Sensor>] = [:]

    init(thingID: ObjectID, maximumSensors: Int) {
        self.thingID = thingID
        self.maximumSensors = maximumSensors
    }

    /// Sensors in a stable order, so a published total never depends on
    /// dictionary iteration order.
    var sortedSensors: [SensorThingsObjectSnapshot<Sensor>] {
        sensors.sorted { $0.key.uuid.isLexicographicallyBefore($1.key.uuid) }.map(\.value)
    }

    /// The complete catalogue as publishable entries.
    var entries: [SensorThingsCatalogueEntry] {
        guard let thing else { return [] }
        return sortedSensors.map { SensorThingsCatalogueEntry(sensor: $0, thing: thing) }
    }

    /// Applies a decoded Thing.
    ///
    /// A first Thing adds every Sensor already held; a replacement changes
    /// them. Identical encoded bytes are ignored, so a repeated Advertise
    /// publishes nothing.
    mutating func apply(thing decoded: SensorThingsObjectSnapshot<Thing>) -> Outcome {
        guard decoded.envelope.objectID == thingID else { return .ignored }
        guard thing?.encodedBytes != decoded.encodedBytes else { return .ignored }
        let hadThing = thing != nil
        thing = decoded
        let kind: SensorThingsCatalogueChangeKind = hadThing ? .changed : .added
        return .changed(sortedSensors.map { Transition(kind: kind, sensor: $0, thing: decoded) })
    }

    /// Applies a decoded Sensor that already passed the caller's filter.
    ///
    /// A Sensor whose parent is not this Thing is ignored, as is one whose
    /// encoded bytes are unchanged. A new Sensor beyond the limit is refused
    /// rather than evicting an existing one.
    mutating func apply(sensor decoded: SensorThingsObjectSnapshot<Sensor>) -> Outcome {
        guard decoded.envelope.parentObjectID == thingID else { return .ignored }
        let id = decoded.envelope.objectID
        if let existing = sensors[id] {
            guard existing.encodedBytes != decoded.encodedBytes else { return .ignored }
            sensors[id] = decoded
            guard let thing else { return .ignored }
            return .changed([Transition(kind: .changed, sensor: decoded, thing: thing)])
        }
        guard sensors.count < maximumSensors else { return .capacityExceeded }
        sensors[id] = decoded
        guard let thing else { return .ignored }
        return .changed([Transition(kind: .added, sensor: decoded, thing: thing)])
    }

    /// Removes one object by identifier.
    ///
    /// Removing the Thing removes every Sensor first, one at a time, so each
    /// transition reports the complete remaining catalogue. Clearing them
    /// together would make every removal report an identical empty total.
    mutating func remove(_ id: ObjectID) -> Outcome {
        if id == thingID {
            guard let oldThing = thing else { return .ignored }
            var transitions: [Transition] = []
            for sensorID in sensors.keys.sorted(by: { $0.uuid.isLexicographicallyBefore($1.uuid) }) {
                guard let sensor = sensors.removeValue(forKey: sensorID) else { continue }
                transitions.append(Transition(kind: .removed, sensor: sensor, thing: oldThing))
            }
            thing = nil
            return transitions.isEmpty ? .ignored : .changed(transitions)
        }
        guard let sensor = sensors.removeValue(forKey: id) else { return .ignored }
        return .changed([Transition(kind: .removed, sensor: sensor, thing: thing)])
    }

    /// Whether an Observation may be delivered for `sensorID`.
    ///
    /// The Sensor must be catalogued and still parented by this Thing.
    func deliverableSensor(_ sensorID: ObjectID) -> (SensorThingsObjectSnapshot<Sensor>, SensorThingsObjectSnapshot<Thing>)? {
        guard let sensor = sensors[sensorID],
              let thing,
              sensor.envelope.parentObjectID == thingID else { return nil }
        return (sensor, thing)
    }
}

extension SensorThingsCatalogue.Outcome {
    /// Nothing changed.
    var isIgnored: Bool { if case .ignored = self { return true }; return false }
    /// The catalogue refused a new Sensor.
    var isCapacityExceeded: Bool { if case .capacityExceeded = self { return true }; return false }
    /// Transitions to publish, empty when nothing changed.
    var transitions: [SensorThingsCatalogue.Transition] {
        if case let .changed(values) = self { return values }
        return []
    }
}

extension UUID16 {
    /// Byte-order comparison, used to keep catalogue ordering stable.
    ///
    /// Previously duplicated as a fileprivate helper in two files.
    func isLexicographicallyBefore(_ other: UUID16) -> Bool {
        withUnsafeBytes(of: bytes) { left in
            withUnsafeBytes(of: other.bytes) { right in
                for index in 0..<16 {
                    if left[index] != right[index] { return left[index] < right[index] }
                }
                return false
            }
        }
    }
}
