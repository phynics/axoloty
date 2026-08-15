// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import ErrorKit
import Foundation
import Logging

/// Provides rate-aware publishing for IO sources and async association observation.
open class IoSourceController: Controller {
    var sourceItems: [CoatyUUID: (source: IoSource, associated: Bool, updateRate: Int?)] = [:]
    private let log = LogManager.logger(.ioRouting)

    override open func onInit() {
        super.onInit()
        sourceItems.removeAll()
    }

    /// Publishes a value when the source currently has an association.
    ///
    /// A value for an unassociated source is dropped and logged at `notice`
    /// (deliberate back-pressure). A value whose data format does not match the
    /// source's raw/JSON configuration cannot be published; that failure is
    /// logged at `error` with the wrapped ``AxolotyError`` chain so the loss is
    /// diagnosable. Publication remains best-effort.
    public func publish(source: IoSource, value: Any) {
        let item = sourceItems[source.objectId] ?? (source, false, nil)
        sourceItems[source.objectId] = item
        guard item.associated else {
            // Deliberate back-pressure: a value published for an unassociated
            // source is dropped. Logged (not silent) so the loss is observable
            // while remaining best-effort.
            self.log.notice("Dropped IoValue for unassociated source", metadata: [
                "ioSourceId": .string(source.objectId.string),
                "ioRoute": .string(communicationManager.createIoRoute(ioSource: source)),
            ])
            return
        }
        let event: IoValueEvent?
        var constructionError: Error?
        do {
            if source.useRawIoValues == true, let raw = value as? [UInt8] {
                event = try IoValueEvent.with(ioSource: source, value: raw, options: .init())
            } else {
                event = try IoValueEvent.with(ioSource: source, value: RawJSONValue.serialize(any: value), options: .init())
            }
        } catch {
            event = nil
            constructionError = error
        }
        guard let event else {
            log.error("Failed to construct IoValue event; value not published", metadata: [
                "ioSourceId": .string(source.objectId.string),
                "ioRoute": .string(communicationManager.createIoRoute(ioSource: source)),
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(constructionError ?? AxolotyError.invalidArgument(
                    argument: "value",
                    reason: "value is not compatible with the IoSource's raw/JSON data format"
                )))),
            ])
            return
        }
        communicationManager.publishIoValue(event: event)
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
