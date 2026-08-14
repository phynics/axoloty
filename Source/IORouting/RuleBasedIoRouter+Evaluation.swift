//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  RuleBasedIoRouter+Evaluation.swift
//  Axoloty
//

import ErrorKit
import Foundation

extension RuleBasedIoRouter {
    // MARK: - Single-pass rule evaluation.

    /// Reconciles associations in a single pass over the reconciled value-type
    /// buckets: each bucket is traversed once to compute the desired
    /// source -> actor associations (applying rules and resolving cumulated
    /// update rates per source), then the desired set is diffed against the
    /// currently active associations and Associate/Disassociate events are
    /// published accordingly.
    ///
    /// When `affectedBuckets` is non-nil, only the pairs and current
    /// associations within those buckets are reconsidered; associations in
    /// untouched buckets are left as-is. A `nil` value reconciles everything
    /// (used on context change, rule definition, and whenever value-type
    /// compatibility is overridden).
    func evaluateRules(affectedBuckets: Set<ValueTypeBucket>?) {
        // Desired associations accumulated during the single traversal:
        // source ID -> actor ID -> (source, actor, per-pair rate). Built and
        // consumed within this method (no intermediate compatible-pairs list
        // and no reference-type box handed between stages).
        var desired: IoAssociationPairs = [:]

        if usesDefaultValueTypeCompatibility {
            let buckets: [ValueTypeBucket: IoBucketEntry]
            if let affected = affectedBuckets {
                buckets = ioIndex.filter { affected.contains($0.key) }
            } else {
                buckets = managedBuckets()
            }
            for entry in buckets.values {
                appendDesiredPairs(in: entry, to: &desired)
            }
        } else {
            // Value-type compatibility is overridden: the bucket key can no
            // longer be assumed to partition compatible pairs, so fall back
            // to an exhaustive cross that consults `areValueTypesCompatible`
            // for every candidate pair (honoring the override).
            appendDesiredPairsExhaustive(to: &desired)
        }

        resolveCumulatedRates(desired: &desired)
        reconcile(desired: desired, affectedBuckets: affectedBuckets)
    }

    func evaluateRules() {
        evaluateRules(affectedBuckets: nil)
    }

    /// For each source x actor in a bucket, applies the matching rule and
    /// records the pair with its per-pair update rate. Under the default
    /// compatibility check, every within-bucket pair is compatible by
    /// construction, so `areValueTypesCompatible` is not consulted here.
    private func appendDesiredPairs(in entry: IoBucketEntry, to desired: inout IoAssociationPairs) {
        entry.sources.forEach { _, sourcePair in
            let (source, sourceNode) = sourcePair
            entry.actors.forEach { _, actorPair in
                let (actor, actorNode) = actorPair
                if let rate = rateIfRuleMatches(source: source, sourceNode: sourceNode,
                                                 actor: actor, actorNode: actorNode) {
                    desired[source.objectId.string, default: [:]][actor.objectId.string] = (source, actor, rate)
                }
            }
        }
    }

    /// Exhaustive cross of every managed source against every managed actor,
    /// keeping pairs for which `areValueTypesCompatible` returns true. Used
    /// when value-type compatibility is overridden (bucketing unsound).
    private func appendDesiredPairsExhaustive(to desired: inout IoAssociationPairs) {
        var sources: [(IoSource, IoNode)] = []
        var actors: [(IoActor, IoNode)] = []
        self.managedIoNodes.forEach { _, node in
            node.ioSources.forEach { sources.append(($0, node)) }
            node.ioActors.forEach { actors.append(($0, node)) }
        }
        sources.forEach { sourcePair in
            let (source, sourceNode) = sourcePair
            actors.forEach { actorPair in
                let (actor, actorNode) = actorPair
                guard self.areValueTypesCompatible(source: source, actor: actor) else { return }
                if let rate = rateIfRuleMatches(source: source, sourceNode: sourceNode,
                                                 actor: actor, actorNode: actorNode) {
                    desired[source.objectId.string, default: [:]][actor.objectId.string] = (source, actor, rate)
                }
            }
        }
    }

    /// Returns the per-pair update rate if a rule matches the pair, or `nil`
    /// if no rule matches. Increments `conditionInvocationCount` once per
    /// condition invocation (including nil-returning ones).
    private func rateIfRuleMatches(source: IoSource,
                                   sourceNode: IoNode,
                                   actor: IoActor,
                                   actorNode: IoNode) -> Int? {
        let valueType = source.valueType
        guard let rules = self.rules[valueType] ?? self.rules[""] else { return nil }
        for rule in rules {
            self.conditionInvocationCount += 1

            guard let isMatch = rule.condition(source, sourceNode, actor, actorNode, self.ioContext, self) else {
                LogManager.logger(.ioRouting).error("Rule condition invocation returned nil", metadata: [
                    "ioSourceId": .string(source.objectId.string),
                    "ioActorId": .string(actor.objectId.string),
                    "valueType": .string(valueType),
                ])
                continue
            }

            if isMatch {
                // This is the documented per-association effective-rate
                // decision point. Dynamic dispatch lets router subclasses
                // supply a custom cadence without changing publication.
                return self.normalizedUpdateRate(self.computeDefaultUpdateRate(
                    source: source, actor: actor, sourceNode: sourceNode, actorNode: actorNode))
            }
        }
        return nil
    }

    /// Resolves, per source, the cumulated update rate across all its desired
    /// actors (the max), and assigns it to every actor of that source.
    private func resolveCumulatedRates(desired: inout IoAssociationPairs) {
        for (sourceId, actors) in desired {
            var cumulatedRate = 0
            for (_, value) in actors {
                cumulatedRate = self.normalizedUpdateRate(
                    self.computeCumulatedUpdateRate(rate1: value.2, rate2: cumulatedRate))
            }
            var updated = actors
            for (key, value) in updated {
                var info = value
                info.2 = cumulatedRate
                updated[key] = info
            }
            desired[sourceId] = updated
        }
    }

    /// Diffs the desired associations against `currentAssociations` and
    /// publishes Associate/Disassociate events. Only successfully published
    /// associations are recorded in `currentAssociations`; a failed publish
    /// leaves the pair out so the next evaluation republishes it
    /// (self-healing, truthful router state). Associations outside
    /// `affectedBuckets` (when non-nil) are left untouched.
    private func reconcile(desired: IoAssociationPairs, affectedBuckets: Set<ValueTypeBucket>?) {
        var remaining = desired
        var newAssociations = [IoAssociationInfo]()

        self.currentAssociations.forEach { source, actor, rate in
            // Outside the reconciled scope (incremental path): leave untouched.
            if let affected = affectedBuckets, !affected.contains(ValueTypeBucket(source)) {
                newAssociations.append((source, actor, rate))
                if var actors = remaining[source.objectId.string] {
                    actors.removeValue(forKey: actor.objectId.string)
                    remaining[source.objectId.string] = actors
                }
                return
            }

            if let actors = remaining[source.objectId.string], let info = actors[actor.objectId.string] {
                let (resolvedSrc, resolvedAct, resolvedRate) = info
                var shouldKeep = true
                if resolvedRate != rate {
                    // Keep the current association but with the new update rate.
                    do {
                        try self.associate(source: resolvedSrc, actor: resolvedAct, updateRate: resolvedRate)
                    } catch {
                        self.logPublishFailure(error, source: resolvedSrc, actor: resolvedAct, operation: "update")
                        // Drop from current associations and from `remaining`
                        // so it isn't retried this round; the next evaluation
                        // sees the pair as new and republishes (self-healing).
                        shouldKeep = false
                    }
                }
                if shouldKeep {
                    newAssociations.append(info)
                }

                // Remove the resolved pair so that remaining pairs can be
                // identified as being new associations.
                if var updated = remaining[source.objectId.string] {
                    updated.removeValue(forKey: actor.objectId.string)
                    remaining[source.objectId.string] = updated
                }
            } else {
                do {
                    try self.disassociate(source: source, actor: actor)
                } catch {
                    self.logPublishFailure(error, source: source, actor: actor, operation: "disassociate")
                }
            }
        }

        // Add the remaining desired pairs as new associations.
        remaining.forEach { _, newActors in
            newActors.forEach { _, info in
                let (src, act, rate) = info
                do {
                    try self.associate(source: src, actor: act, updateRate: rate)
                    newAssociations.append(info)
                } catch {
                    self.logPublishFailure(error, source: src, actor: act, operation: "associate")
                }
            }
        }

        self.currentAssociations = newAssociations
    }

    private func managedBuckets() -> [ValueTypeBucket: IoBucketEntry] {
        var buckets: [ValueTypeBucket: IoBucketEntry] = [:]
        self.managedIoNodes.forEach { _, node in
            node.ioSources.forEach { src in
                buckets[ValueTypeBucket(src), default: IoBucketEntry()].sources[src.objectId.string] = (src, node)
            }
            node.ioActors.forEach { actor in
                buckets[ValueTypeBucket(actor), default: IoBucketEntry()].actors[actor.objectId.string] = (actor, node)
            }
        }
        return buckets
    }

    private func logPublishFailure(_ error: Error, source: IoSource, actor: IoActor, operation: String) {
        LogManager.logger(.ioRouting).error(
            "Associate/Disassociate publish failed; pair left out of current associations for retry",
            metadata: [
                "ioSourceId": .string(source.objectId.string),
                "ioActorId": .string(actor.objectId.string),
                "operation": .string(operation),
                "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
            ])
    }

    /// Resets the test-visible condition-invocation counter.
    func resetConditionInvocationCount() {
        self.conditionInvocationCount = 0
    }

    func computeCumulatedUpdateRate(rate1: Int?, rate2: Int?) -> Int? {
        switch (rate1, rate2) {
        case (.none, .none):
            return nil
        case (.some(let r), .none):
            return r
        case (.none, .some(let r)):
            return r
        case (.some(let a), .some(let b)):
            return max(a, b)
        }
    }

    /// Normalizes an optional update rate at the routing boundary.
    ///
    /// `nil` means that no cadence was requested and retains the existing zero
    /// fallback. Negative rates are invalid and are handled the same way so
    /// that no invalid cadence is passed to association publication.
    func normalizedUpdateRate(_ rate: Int?) -> Int {
        guard let rate, rate >= 0 else { return 0 }
        return rate
    }

    /// Whether `areValueTypesCompatible` retains its default semantics, so
    /// the `(valueType, useRawIoValues)` bucket exactly partitions
    /// compatible pairs and within-bucket crossing is sound.
    ///
    /// Pure Swift cannot portably detect whether a non-`@objc` method has
    /// been overridden, so the framework treats its own non-overriding
    /// router types (`RuleBasedIoRouter`, `BasicIoRouter`) as the known-safe
    /// set and treats any other dynamic type as potentially overriding ->
    /// exhaustive crossing. This is conservative: a subclass that does not
    /// override `areValueTypesCompatible` still routes correctly, it just
    /// does not benefit from the bucketed fast path. A subclass that
    /// overrides `areValueTypesCompatible` is guaranteed correct behavior
    /// because the exhaustive fallback consults the override for every pair.
    internal var usesDefaultValueTypeCompatibility: Bool {
        let dynamicType = type(of: self)
        return dynamicType === RuleBasedIoRouter.self || dynamicType === BasicIoRouter.self
    }
}
