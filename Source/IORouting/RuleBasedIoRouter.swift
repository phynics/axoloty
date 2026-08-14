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
    internal var currentAssociations: [(IoSource, IoActor, Int)] = []

    /// Defined rules hashed by value type.
    ///
    /// Key: value type, Value: the array of rules for that value type. An
    /// empty key (`""`) holds the global rules. A plain value-type `Array`
    /// is sufficient here: `defineRules` writes each bucket back via
    /// subscript defaulting, so the per-value-type array accumulates without
    /// reference semantics.
    internal var rules: [String: [IoAssociationRule]] = [:]

    /// Bucketed index of managed IO sources and actors, keyed by
    /// `(valueType, useRawIoValues)`, maintained incrementally on node
    /// lifecycle events. Lets a single node advertise/deadvertise cross only
    /// the value-type buckets the changed node belongs to, instead of the
    /// full source x actor product.
    internal var ioIndex: [ValueTypeBucket: IoBucketEntry] = [:]

    /// Reverse map from a managed node's object ID to the IO point IDs and
    /// buckets currently held for that node in `ioIndex`. Re-advertisement
    /// replaces a node's points without going through `onIoNodesUnmanaged`,
    /// so this map lets `registerIoNodeInIndex` remove a node's stale points
    /// before adding the new ones (see `ioNodesDeadvertised` /
    /// `sourceRoutes` preservation in `IoRouter`).
    internal var indexedNodes: [String: IndexedNode] = [:]

    /// Test-visible counter of rule-condition invocations, incremented once
    /// per `IoRoutingRuleConditionFunc` call. Tests assert it against
    /// bucket-product bounds (not a fixed number, so it does not become a
    /// change detector). Reset via `resetConditionInvocationCount`.
    internal var conditionInvocationCount: Int = 0

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
        if let rules = self.options?.ioAssociationRulesOption {
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
    /// A negative rate returned by an override is invalid and is normalized to
    /// zero before the association is published.
    ///
    /// - Parameters:
    ///     - source: the IoSource object
    ///     - actor the IoActor object
    ///     - sourceNode the IO source's node
    ///     - actorNode the IO actor's node
    func computeDefaultUpdateRate(source: IoSource,
                                   actor: IoActor,
                                   sourceNode: IoNode,
                                   actorNode: IoNode) -> Int {
        return self.normalizedUpdateRate(
            self.computeCumulatedUpdateRate(rate1: source.updateRate, rate2: actor.updateRate))
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

}
