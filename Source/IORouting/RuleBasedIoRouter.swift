//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  RuleBasedIoRouter.swift
//  Axoloty
//
//

import ErrorKit
import Foundation

/// Supports rule-based routing of data from IO sources to IO actors based on an
/// associated IO context.
///
/// Define rules that determine whether a given pair of IO source and IO actor
/// should be associated or not. A rule is only applied if the value type of IO
/// source and IO actor are compatible. If no rules are defined or no rule
/// matches no associations between IO sources and IO actors are established.
///
/// You can define global rules that match IO sources and actors of any
/// compatible value type or value-type specific rules that are only applied to
/// IO sources and IO actors with a given value type.
///
/// By default, an IO source and an IO actor are compatible if both define equal
/// value types in equal data formats. You can define your own custom
/// compatibility check on value types in a subclass by overriding the
/// `areValueTypesCompatible` method.
///
/// Note that this router makes its IO context available by advertising and for
/// discovery (by core type, object type, or object Id) and listens for
/// Update-Complete events on its IO context, triggering `onIoContextChanged`
/// automatically.
///
/// This router requires the following controller options:
/// - `ioContext`: the IO context for which this router is managing routes
///    (mandatory)
/// - `rules`: an array of rule definitions for this router. The rules listed
///   here override any rules defined in the `onInit` method.
public class RuleBasedIoRouter: IoRouter {

    // MARK: - Attributes.

    /// An array of current association items.
    ///
    /// Exposed `internal` so tests can assert router state directly. Only
    /// this class mutates it (via `reconcile` / `onStopped`).
    internal private(set) var currentAssociations: [(IoSource, IoActor, Int)] = []

    /// Defined rules hashed by value type.
    ///
    /// Key: value type, Value: the array of rules for that value type. An
    /// empty key (`""`) holds the global rules. A plain value-type `Array`
    /// is sufficient here: `defineRules` writes each bucket back via
    /// subscript defaulting, so the per-value-type array accumulates without
    /// reference semantics.
    private var rules: [String: [IoAssociationRule]] = [:]

    /// Bucketed index of managed IO sources and actors, keyed by
    /// `(valueType, useRawIoValues)`, maintained incrementally on node
    /// lifecycle events. Lets a single node advertise/deadvertise cross only
    /// the value-type buckets the changed node belongs to, instead of the
    /// full source x actor product.
    private var ioIndex: [ValueTypeBucket: IoBucketEntry] = [:]

    /// Reverse map from a managed node's object ID to the IO point IDs and
    /// buckets currently held for that node in `ioIndex`. Re-advertisement
    /// replaces a node's points without going through `onIoNodesUnmanaged`,
    /// so this map lets `registerIoNodeInIndex` remove a node's stale points
    /// before adding the new ones (see `ioNodesDeadvertised` /
    /// `sourceRoutes` preservation in `IoRouter`).
    private var indexedNodes: [String: IndexedNode] = [:]

    /// Test-visible counter of rule-condition invocations, incremented once
    /// per `IoRoutingRuleConditionFunc` call. Tests assert it against
    /// bucket-product bounds (not a fixed number, so it does not become a
    /// change detector). Reset via `resetConditionInvocationCount`.
    internal private(set) var conditionInvocationCount: Int = 0

    // MARK: - Overridden lifecycle methods.

    public override func onInit() {
        super.onInit()
        self.currentAssociations = []
        self.rules = [:]
        self.ioIndex = [:]
        self.indexedNodes = [:]
        self.conditionInvocationCount = 0
    }

    /// Invoked when the IO context of this router has changed.
    ///
    /// Triggers reevaluation of all defined rules.
    override func onIoContextChanged() throws {
        try super.onIoContextChanged()
        self.evaluateRules()
    }

    // MARK: - Overridden methods.

    /// Define all association rules for routing.
    ///
    /// Note that any previously defined rules are discarded.
    ///
    /// Rules with undefined condition function are ignored.
    ///
    /// - Parameter rules: association rules for this IO router
    func defineRules(rules: [IoAssociationRule]) {
        self.rules = [:]

        rules.forEach { rule in
            let valueType = rule.valueType ?? ""
            self.rules[valueType, default: []].append(rule)
        }

        self.evaluateRules()
    }

    override func onStarted() {
        if let rules = self.options?.extra["rules"] as? [IoAssociationRule] {
            self.defineRules(rules: rules)
        }

        super.onStarted()
    }

    override func onStopped() {
        // Teardown: nothing observes router state afterward, so disassociate
        // publishes are best-effort and not propagated. Per the repo's
        // absorbed-error policy each failure is logged (with its error chain)
        // rather than silently swallowed; this is the deliberate exception to
        // the publish-failure-truthfulness invariant enforced in `reconcile`,
        // which applies to steady-state evaluation only.
        self.currentAssociations.forEach { source, actor, _ in
            do {
                try self.disassociate(source: source, actor: actor)
            } catch {
                LogManager.logger(.ioRouting).warning(
                    "Disassociate publish failed during teardown; continuing best-effort",
                    metadata: [
                        "ioSourceId": .string(source.objectId.string),
                        "ioActorId": .string(actor.objectId.string),
                        "error": .string(ErrorKit.errorChainDescription(for: AxolotyError.caught(error))),
                    ])
            }
        }

        self.currentAssociations = []
        self.ioIndex = [:]
        self.indexedNodes = [:]

        super.onStopped()
    }

    /// The default function used to compute the recommended update rate of an
    /// individual IO source - IO actor association.
    ///
    /// This function takes into account the maximum possible update rate of the
    /// source and the desired update rate of the actor and returns a value that
    /// satisfies both rates.
    ///
    /// Override this method in a subclass to implement a custom rate function.
    ///
    /// - Parameters:
    ///     - source: the IoSource object
    ///     - actor the IoActor object
    ///     - sourceNode the IO source's node
    ///     - sourceNode the IO actor's node
    func computeDefaultUpdateRate(source: IoSource,
                                   actor: IoActor,
                                   sourceNode: IoNode,
                                   actorNode: IoNode) -> Int {
        switch (source.updateRate, actor.updateRate) {
        case (.none, .none):
            return 0
        case (.some(let r), .none):
            return r
        case (.none, .some(let r)):
            return r
        case (.some(let a), .some(let b)):
            return max(a, b)
        }
    }

    override func onIoNodeManaged(node: IoNode) {
        // Re-advertisement: capture the node's previously indexed buckets so
        // the affected-buckets set covers both the stale points being removed
        // and the new points being added (a point may even move buckets).
        let oldBuckets = indexedNodes[node.objectId.string]?.buckets ?? []
        registerIoNodeInIndex(node)
        let newBuckets = indexedNodes[node.objectId.string]?.buckets ?? []
        evaluateRules(affectedBuckets: affectedBucketsForEval(oldBuckets.union(newBuckets)))
    }

    override func onIoNodesUnmanaged(nodes: [IoNode]) {
        // The base class has already removed these nodes from
        // `managedIoNodes`; capture their buckets from the index (still
        // populated) before unregistering, then reconcile exactly those
        // buckets so stale associations are disassociated.
        var buckets: Set<ValueTypeBucket> = []
        for node in nodes {
            if let indexed = indexedNodes[node.objectId.string] {
                buckets.formUnion(indexed.buckets)
            }
        }
        unregisterIoNodesFromIndex(nodes)
        evaluateRules(affectedBuckets: affectedBucketsForEval(buckets))
    }

    /// Returns the buckets to restrict evaluation to, or `nil` for a full
    /// pass. A full pass is used when value-type compatibility has been
    /// overridden (bucketing is unsound) or when there are no affected
    /// buckets (e.g. context change / rule definition).
    private func affectedBucketsForEval(_ buckets: Set<ValueTypeBucket>) -> Set<ValueTypeBucket>? {
        guard usesDefaultValueTypeCompatibility, !buckets.isEmpty else { return nil }
        return buckets
    }

    /// Adds a node's IO points to the bucketed index. Re-advertisement (same
    /// object ID, changed points) first removes the node's previously indexed
    /// points so stale entries don't linger.
    internal func registerIoNodeInIndex(_ node: IoNode) {
        if indexedNodes[node.objectId.string] != nil {
            unregisterIoNodeFromIndex(node.objectId.string)
        }
        var indexed = IndexedNode()
        for source in node.ioSources {
            let bucket = ValueTypeBucket(source)
            ioIndex[bucket, default: IoBucketEntry()].sources[source.objectId.string] = (source, node)
            indexed.sourceIds.insert(source.objectId.string)
            indexed.buckets.insert(bucket)
        }
        for actor in node.ioActors {
            let bucket = ValueTypeBucket(actor)
            ioIndex[bucket, default: IoBucketEntry()].actors[actor.objectId.string] = (actor, node)
            indexed.actorIds.insert(actor.objectId.string)
            indexed.buckets.insert(bucket)
        }
        indexedNodes[node.objectId.string] = indexed
    }

    /// Removes the given nodes' IO points from the bucketed index.
    internal func unregisterIoNodesFromIndex(_ nodes: [IoNode]) {
        for node in nodes {
            unregisterIoNodeFromIndex(node.objectId.string)
        }
    }

    private func unregisterIoNodeFromIndex(_ nodeId: String) {
        guard let indexed = indexedNodes[nodeId] else { return }
        for id in indexed.sourceIds {
            for bucket in indexed.buckets {
                ioIndex[bucket]?.sources.removeValue(forKey: id)
            }
        }
        for id in indexed.actorIds {
            for bucket in indexed.buckets {
                ioIndex[bucket]?.actors.removeValue(forKey: id)
            }
        }
        indexedNodes.removeValue(forKey: nodeId)
    }

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
                return self.computeCumulatedUpdateRate(rate1: source.updateRate, rate2: actor.updateRate) ?? 0
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
                cumulatedRate = self.computeCumulatedUpdateRate(rate1: value.2, rate2: cumulatedRate) ?? 0
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

// MARK: - Additional type declarations.

/// A `(valueType, useRawIoValues)` pair used to bucket IO sources and actors
/// for incremental, within-bucket pair crossing. Under the default
/// `areValueTypesCompatible` implementation, two IO points are compatible iff
/// they share this bucket.
struct ValueTypeBucket: Hashable {
    let valueType: String
    let useRawIoValues: Bool?

    init(_ source: IoSource) {
        self.valueType = source.valueType
        self.useRawIoValues = source.useRawIoValues
    }

    init(_ actor: IoActor) {
        self.valueType = actor.valueType
        self.useRawIoValues = actor.useRawIoValues
    }
}

/// The managed IO sources and actors sharing a `ValueTypeBucket`, as
/// dictionaries keyed by point object ID (deduplicating re-advertised points).
struct IoBucketEntry {
    var sources: [String: (IoSource, IoNode)] = [:]
    var actors: [String: (IoActor, IoNode)] = [:]
}

/// Per-node record of the IO point IDs and buckets currently held in `ioIndex`,
/// used to remove a node's stale points on re-advertisement.
struct IndexedNode {
    var sourceIds: Set<String> = []
    var actorIds: Set<String> = []
    var buckets: Set<ValueTypeBucket> = []
}

/// Condition function type for IO routing rules.
public typealias IoRoutingRuleConditionFunc = (
    _ source: IoSource,
    _ sourceNode: IoNode,
    _ actor: IoActor,
    _ actorNode: IoNode,
    _ context: IoContext,
    _ router: RuleBasedIoRouter) -> Bool?

/// Defines a rule for associating IO sources with IO actors.
public struct IoAssociationRule {
    /// The name of the rule. Used for display purposes only.
    var name: String

    /// The value type for which the rule is applicable. The rule is applied to
    /// all IO source - IO actor pairs whose value type matches this value type.
    ///
    /// If the value type is nil or an empty string, the rule acts as a
    /// global rule. It applies to all IO source - IO actor pairs that have
    /// compatible value types. Non-global rules have precedence over global
    /// rules. Global rules only apply if there are no non-global rules whose
    /// value type matches the value type of the corresponding IO source - IO
    /// actor pair.
    var valueType: String?

    /// The rule condition function.
    ///
    /// When applied, the condition function is passed a pair of value-compatible
    /// IO source and actor that are eligible for association.
    ///
    /// The condition function should return true if the passed-in association
    /// pair should be associated; false or nil otherwise.
    ///
    /// Eventually, an association pair is associated if there is at least one
    /// applicable rule that returns true; otherwise the association pair
    /// is not associated, i.e. it is actively disassociated if currently
    /// associated.
    ///
    /// - Note: Conditions must be pure functions of their arguments. The
    ///   bucketed evaluation pipeline (#116) restricts pair enumeration to
    ///   the buckets touched by a triggering event, so a condition whose
    ///   verdict depends on state outside its own pair would silently keep a
    ///   stale verdict for untouched pairs. The exhaustive fallback used
    ///   when `areValueTypesCompatible` is overridden preserves the
    ///   re-evaluate-everything contract.
    var condition: IoRoutingRuleConditionFunc

    /// All public structs need public inits, otherwise the compiler sees them as internal.
    public init(name: String, valueType: String?, condition: @escaping IoRoutingRuleConditionFunc) {
        self.name = name
        self.valueType = valueType
        self.condition = condition
    }
}

/// A tuple describing an association pair with its update rate.
typealias IoAssociationInfo = (IoSource, IoActor, Int)

/// Desired associations accumulated during a single evaluation pass:
/// source ID -> actor ID -> association info. A plain value-type nested
/// dictionary built and consumed within `evaluateRules` -- no reference-type
/// box is needed (the box that used to live here is gone, see #116).
typealias IoAssociationPairs = [String: [String: IoAssociationInfo]]
