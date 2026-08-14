//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  RuleBasedIoRouter+Types.swift
//  Axoloty
//

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
