// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Provides rate-aware publishing for IO sources and async association observation.
open class IoSourceController: Controller {
    private var sourceItems: [CoatyUUID: (source: IoSource, associated: Bool, updateRate: Int?)] = [:]

    override open func onInit() {
        super.onInit()
        sourceItems.removeAll()
    }

    /// Publishes a value when the source currently has an association.
    public func publish(source: IoSource, value: Any) {
        let item = sourceItems[source.objectId] ?? (source, false, nil)
        sourceItems[source.objectId] = item
        guard item.associated else { return }
        if source.useRawIoValues == true, let raw = value as? [UInt8], let event = try? IoValueEvent.with(ioSource: source, value: raw, options: .init()) {
            communicationManager.publishIoValue(event: event)
        } else if let event = try? IoValueEvent.with(ioSource: source, value: RawJSONValue.serialize(any: value), options: .init()) {
            communicationManager.publishIoValue(event: event)
        }
    }

    /// Observes update-rate state snapshots for a source.
    public func observeUpdateRate(source: IoSource) async -> AsyncStream<IoStateEventSnapshot> {
        await communicationManager.observeIoStateStream(ioPoint: source)
    }

    /// Observes association state snapshots for a source.
    public func observeAssociation(source: IoSource) async -> AsyncStream<IoStateEventSnapshot> {
        await communicationManager.observeIoStateStream(ioPoint: source)
    }

    /// Determines whether a source is currently associated.
    public func isAssociated(source: IoSource) -> Bool {
        sourceItems[source.objectId]?.associated ?? false
    }
}
