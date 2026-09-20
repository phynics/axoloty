// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Topic-name and topic-filter rules for MQTT 3.1.1 (OASIS section 4.7).
///
/// The broker uses this to route `PUBLISH` packets to matching subscriptions.
/// It is public because broker-backed tests assert subscription behaviour and
/// a test that filters on a typo in the matcher would hide the defect.
public enum MQTTTopicMatcher {
    /// Returns `true` when `filter` selects `topic`.
    ///
    /// `+` matches exactly one level. `#` matches the remaining levels,
    /// including the parent, so `sport/#` matches both `sport` and
    /// `sport/tennis`. A leading wildcard does not match a `$`-prefixed topic,
    /// which keeps `#` from selecting a broker's `$SYS` tree.
    public static func matches(filter: String, topic: String) -> Bool {
        let filterLevels = filter.split(separator: "/", omittingEmptySubsequences: false)
        let topicLevels = topic.split(separator: "/", omittingEmptySubsequences: false)
        if topic.hasPrefix("$"), let first = filterLevels.first, first == "+" || first == "#" {
            return false
        }
        var index = 0
        while index < filterLevels.count {
            let level = filterLevels[index]
            if level == "#" { return true }
            guard index < topicLevels.count else { return false }
            if level != "+", level != topicLevels[index] { return false }
            index += 1
        }
        return index == topicLevels.count
    }

    /// Returns `true` when `filter` obeys the wildcard-placement rules.
    ///
    /// `+` must occupy a whole level, and `#` must be the last level.
    public static func isValidFilter(_ filter: String) -> Bool {
        guard !filter.isEmpty, !filter.contains("\u{0000}") else { return false }
        let levels = filter.split(separator: "/", omittingEmptySubsequences: false)
        for (index, level) in levels.enumerated() {
            if level.contains("#") {
                guard level == "#", index == levels.count - 1 else { return false }
            }
            if level.contains("+"), level != "+" { return false }
        }
        return true
    }

    /// Returns `true` when `topic` is a legal `PUBLISH` topic name.
    ///
    /// A topic name carries no wildcards and is at least one level long.
    public static func isValidTopicName(_ topic: String) -> Bool {
        guard !topic.isEmpty, !topic.contains("\u{0000}") else { return false }
        return !topic.contains("+") && !topic.contains("#")
    }
}
