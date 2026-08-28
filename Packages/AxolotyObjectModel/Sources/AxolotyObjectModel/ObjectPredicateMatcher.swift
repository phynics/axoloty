// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

private enum PredicateScratchLimits {
    // Predicate string comparison has a separate measured scalar bound.
    // Overflow is a deterministic non-match, never truncation.
    static let scalarCapacity = 512
}

/// Internal, bounded JSON matching operations used by ``ObjectPredicate``.
enum ObjectPredicateMatcher {
    static func compareStrings(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Int? {
        // Predicate comparison retains at most 512 decoded scalars. Overflow is a
        // deterministic non-match, never silent truncation.
        var left = InlineArray<512, UInt32>(repeating: 0)
        var right = InlineArray<512, UInt32>(repeating: 0)
        var lc = 0; var rc = 0; var overflow = false
        try? lhs.withStringScalars { if lc < PredicateScratchLimits.scalarCapacity { left[lc] = $0; lc += 1 } else { overflow = true } }
        try? rhs.withStringScalars { if rc < PredicateScratchLimits.scalarCapacity { right[rc] = $0; rc += 1 } else { overflow = true } }
        guard !overflow else { return nil }
        for index in 0..<min(lc, rc) where left[index] != right[index] { return left[index] < right[index] ? -1 : 1 }
        return lc == rc ? 0 : (lc < rc ? -1 : 1)
    }

    static func jsonEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        let left = lhs.wireValueKind; let right = rhs.wireValueKind
        if left == .number && right == .number { return PredicateDecimalComparison.compare(lhs, rhs) == .some(0) }
        if left != right { return false }
        if left == .string { return scalarEqual(lhs, rhs) }
        if left == .object { return objectEqual(lhs, rhs) }
        if left == .array { return arrayEqual(lhs, rhs) }
        return lhs == rhs
    }

    private static func objectEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var leftCount = 0; var result = true
        do throws(WireDecodeError) { try lhs.withBorrowedObjectFields { left in
            leftCount += 1; var found = false
            left.withBorrowedKey { key in
                do throws(WireDecodeError) { try rhs.withBorrowedObjectFields { right in right.withBorrowedKey { rightKey in
                    if key.semanticEquals(rightKey) {
                        right.withBorrowedValue { rv in left.withBorrowedValue { lv in
                            rv.withBorrowedByteSlice { rightBytes in
                                lv.withBorrowedByteSlice { leftBytes in found = jsonEqual(leftBytes, rightBytes) }
                            }
                        } }
                    }
                } } } catch { result = false }
            }
            if !found { result = false }
        }; if result { var rightCount = 0; try rhs.withBorrowedObjectFields { _ in rightCount += 1 }; if rightCount != leftCount { result = false } } } catch { return false }
        return result
    }

    private static func arrayEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var index = 0; var result = true
        do throws(WireDecodeError) { try lhs.withArrayElements { element in
            if !arrayElementEquals(rhs, at: index, to: element) { result = false }; index += 1
        }; if arrayHasElement(rhs, at: index) { result = false } } catch { return false }
        return result
    }

    static func jsonContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        let leftKind = lhs.wireValueKind; let rightKind = rhs.wireValueKind
        if leftKind == .string && rightKind == .string { return stringContains(lhs, rhs) }
        if leftKind == .object && rightKind == .object { return objectContains(lhs, rhs) }
        if leftKind == .array {
            if rightKind == .array {
                var result = true; do throws(WireDecodeError) { try rhs.withArrayElements { requested in if !arrayContains(lhs, requested) { result = false } } } catch { return false }; return result
            }
            return arrayContains(lhs, rhs)
        }
        return jsonEqual(lhs, rhs)
    }

    private static func objectContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var result = true
        do throws(WireDecodeError) { try rhs.withBorrowedObjectFields { wanted in wanted.withBorrowedKey { key in
            var found = false
            try? lhs.withBorrowedObjectFields { candidate in candidate.withBorrowedKey { candidateKey in
                if key.semanticEquals(candidateKey) {
                    candidate.withBorrowedValue { cv in wanted.withBorrowedValue { wv in
                        cv.withBorrowedByteSlice { candidateBytes in wv.withBorrowedByteSlice { wantedBytes in
                            found = jsonContains(candidateBytes, wantedBytes)
                        } }
                    } }
                }
            } }
            if !found { result = false }
        } } } catch { return false }
        return result
    }

    private static func arrayContains(_ lhs: ByteSlice, _ wanted: ByteSlice) -> Bool {
        var found = false; try? lhs.withArrayElements { candidate in if jsonEqual(candidate, wanted) { found = true } }; return found
    }

    static func jsonIn(_ value: ByteSlice, _ values: ByteSlice) -> Bool {
        var found = false; try? values.withArrayElements { candidate in if jsonEqual(value, candidate) { found = true } }; return found
    }

    private static func arrayElementEquals(_ value: ByteSlice, at target: Int, to wanted: ByteSlice) -> Bool {
        var index = 0; var result = false
        try? value.withArrayElements { element in if index == target { result = jsonEqual(element, wanted) }; index += 1 }
        return result
    }

    private static func arrayHasElement(_ value: ByteSlice, at target: Int) -> Bool {
        var index = 0; var result = false
        try? value.withArrayElements { _ in if index == target { result = true }; index += 1 }
        return result
    }

    private static func scalarEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        // Predicate strings have an independent 512-scalar scratch bound.
        var left = InlineArray<512, UInt32>(repeating: 0); var right = InlineArray<512, UInt32>(repeating: 0); var lc = 0; var rc = 0; var overflow = false
        try? lhs.withStringScalars { if lc < PredicateScratchLimits.scalarCapacity { left[lc] = $0; lc += 1 } else { overflow = true } }; try? rhs.withStringScalars { if rc < PredicateScratchLimits.scalarCapacity { right[rc] = $0; rc += 1 }
            else { overflow = true }
        }; guard !overflow, lc == rc else { return false }; for i in 0..<lc where left[i] != right[i] { return false }; return true
    }

    private static func stringContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool { wildcardMatch(lhs, rhs, like: false) }

    static func wildcard(_ value: ByteSlice, _ pattern: ByteSlice) -> Bool { wildcardMatch(value, pattern, like: true) }

    private static func wildcardMatch(_ value: ByteSlice, _ pattern: ByteSlice, like: Bool) -> Bool {
        var text = InlineArray<512, UInt32>(repeating: 0); var pat = InlineArray<512, UInt32>(repeating: 0); var tc = 0; var pc = 0; var overflow = false
        try? value.withStringScalars { if tc < PredicateScratchLimits.scalarCapacity { text[tc] = $0; tc += 1 } else { overflow = true } }; try? pattern.withStringScalars { if pc < PredicateScratchLimits.scalarCapacity { pat[pc] = $0; pc += 1 } else { overflow = true } }
        guard !overflow else { return false }
        if !like {
            if pc == 0 { return true }
            for start in 0...tc where start + pc <= tc {
                var ok = true
                for i in 0..<pc where text[start + i] != pat[i] { ok = false }
                if ok { return true }
            }
            return false
        }
        var ti = 0; var pi = 0; var star = -1; var mark = 0
        while ti < tc {
            // Coaty LIKE uses backslash as the escape character. The wire
            // decoder intentionally leaves that scalar in the pattern, so a
            // JSON `\\\\%` sequence reaches this branch as `\\%` and the
            // percent is matched literally rather than becoming a wildcard.
            if like, pi + 1 < pc, pat[pi] == 0x5C {
                if pat[pi + 1] == text[ti] { ti += 1; pi += 2; continue }
            } else if pi < pc && (pat[pi] == text[ti] || pat[pi] == 0x5F) {
                ti += 1; pi += 1; continue
            } else if like, pi < pc, pat[pi] == 0x25 {
                star = pi; pi += 1; mark = ti; continue
            }
            if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < pc {
            if like, pi + 1 < pc, pat[pi] == 0x5C { return false }
            guard like, pat[pi] == 0x25 else { return false }
            pi += 1
        }
        return true
    }
}
