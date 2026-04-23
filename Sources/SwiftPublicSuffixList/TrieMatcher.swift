//
//  TrieMatcher.swift
//  SwiftPublicSuffixList
//
//  Walks a serialized trie in-place. Holds the backing `Data` alive; each
//  match does a short `withUnsafeBytes` to get a pointer into the mmapped
//  pages, so we never copy the buffer.
//

import Foundation

/// Returned by `TrieMatcher.match(_:)`.
public struct PublicSuffixMatch {
    /// The rule that determined the outcome, with labels in the same
    /// right-to-left order used by the rule set. Exception rules include the
    /// leading `!` on the leftmost label.
    public let prevailingRule: [String]

    /// `true` when the candidate *is* a public suffix (and therefore should
    /// not be treated as a registrable domain).
    public let isRestricted: Bool
}

final class TrieMatcher {

    let data: Data
    let rootOffset: UInt32
    let ruleCount: UInt32

    init(data: Data) {
        self.data = data
        let (root, rules) = data.withUnsafeBytes { raw -> (UInt32, UInt32) in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            precondition(raw.count >= TrieFormat.headerSize, "trie buffer too small")
            precondition(p[0] == 0x50 && p[1] == 0x53 && p[2] == 0x4C && p[3] == 0x54,
                         "bad magic — not a PSLT buffer")
            precondition(p[4] == TrieFormat.version, "unsupported trie version")
            let rootOff = UInt32(p[8])
                        | (UInt32(p[9]) << 8)
                        | (UInt32(p[10]) << 16)
                        | (UInt32(p[11]) << 24)
            let ruleCt = UInt32(p[16])
                       | (UInt32(p[17]) << 8)
                       | (UInt32(p[18]) << 16)
                       | (UInt32(p[19]) << 24)
            return (rootOff, ruleCt)
        }
        self.rootOffset = root
        self.ruleCount = rules
    }

    // MARK: - Public matching

    /// Fast path used by `PublicSuffixList.isUnrestricted`. Zero heap
    /// allocations apart from a small fixed-size label-range array.
    func isUnrestricted(_ candidate: String) -> Bool {
        guard let ranges = validateAndSplit(candidate) else { return false }
        let utf8 = ranges.utf8Bytes
        let labelCount = ranges.labelCount
        let result: (depth: Int, exception: Bool) = data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return utf8.withUnsafeBufferPointer { u in
                ranges.starts.withUnsafeBufferPointer { ls in
                    ranges.ends.withUnsafeBufferPointer { le in
                        walk(base: base,
                             nodeOffset: rootOffset,
                             labelsConsumed: 0,
                             labelCount: labelCount,
                             labelStarts: ls.baseAddress!,
                             labelEnds: le.baseAddress!,
                             utf8: u.baseAddress!)
                    }
                }
            }
        }
        if result.depth == 0 { return false }
        let isRestricted = !result.exception && (labelCount <= result.depth)
        return !isRestricted
    }

    /// Full match path — populates `prevailingRule` by reconstructing the
    /// walked labels. Returns `nil` when the candidate is syntactically
    /// invalid or no rule matches.
    func match(_ candidate: String) -> PublicSuffixMatch? {
        guard let ranges = validateAndSplit(candidate) else { return nil }
        let utf8 = ranges.utf8Bytes
        let labelCount = ranges.labelCount
        let result: (depth: Int, exception: Bool) = data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return utf8.withUnsafeBufferPointer { u in
                ranges.starts.withUnsafeBufferPointer { ls in
                    ranges.ends.withUnsafeBufferPointer { le in
                        walk(base: base,
                             nodeOffset: rootOffset,
                             labelsConsumed: 0,
                             labelCount: labelCount,
                             labelStarts: ls.baseAddress!,
                             labelEnds: le.baseAddress!,
                             utf8: u.baseAddress!)
                    }
                }
            }
        }
        if result.depth == 0 { return nil }
        let isRestricted = !result.exception && (labelCount <= result.depth)

        // Reconstruct prevailing rule labels from the candidate. The walker
        // matches `result.depth` suffix labels — those become the rule body in
        // original (leftmost-first) order. For exception rules, prefix the
        // leftmost label with `!` to match the legacy representation.
        let startLabel = labelCount - result.depth
        var rule: [String] = []
        rule.reserveCapacity(result.depth)
        for i in startLabel..<labelCount {
            let s = String(
                decoding: utf8[ranges.starts[i]..<ranges.ends[i]],
                as: UTF8.self
            )
            rule.append(s)
        }
        if result.exception, !rule.isEmpty {
            rule[0] = "!" + rule[0]
        }
        return PublicSuffixMatch(prevailingRule: rule, isRestricted: isRestricted)
    }

    // MARK: - Host validation + label slicing

    private struct LabelRanges {
        let utf8Bytes: [UInt8]
        let starts: [Int]
        let ends: [Int]
        var labelCount: Int { starts.count }
    }

    private func validateAndSplit(_ candidate: String) -> LabelRanges? {
        guard Self.isValidHost(candidate) else { return nil }
        let utf8 = Array(candidate.utf8)
        var starts: [Int] = [0]
        var ends: [Int] = []
        starts.reserveCapacity(8)
        ends.reserveCapacity(8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x2E {
                ends.append(i)
                starts.append(i + 1)
            }
            i += 1
        }
        ends.append(utf8.count)
        for idx in 0..<starts.count {
            let len = ends[idx] - starts[idx]
            if !(1...63).contains(len) { return nil }
            if utf8[starts[idx]] == 0x2D { return nil } // starts with '-'
            if utf8[ends[idx] - 1] == 0x2D { return nil } // ends with '-'
        }
        return LabelRanges(utf8Bytes: utf8, starts: starts, ends: ends)
    }

    private static let disallowed: Set<UInt8> = {
        var s = Set<UInt8>()
        for c in [UInt8](",~:!@#$%^&'\"(){}_*".utf8) { s.insert(c) }
        for b in UInt8(0)...UInt8(31) { s.insert(b) }
        s.insert(32)  // space
        s.insert(127) // DEL
        return s
    }()

    private static func isValidHost(_ s: String) -> Bool {
        let count = s.utf8.count
        guard (1...253).contains(count) else { return false }
        if s.hasPrefix(".") || s.hasSuffix(".") { return false }
        for b in s.utf8 where disallowed.contains(b) { return false }
        return true
    }

    // MARK: - Walker

    private func walk(
        base: UnsafePointer<UInt8>,
        nodeOffset: UInt32,
        labelsConsumed: Int,
        labelCount: Int,
        labelStarts: UnsafePointer<Int>,
        labelEnds: UnsafePointer<Int>,
        utf8: UnsafePointer<UInt8>
    ) -> (depth: Int, exception: Bool) {
        let np = base + Int(nodeOffset)
        let flags = np[0]
        let isTerminal = (flags & TrieFormat.flagTerminal) != 0
        let isException = (flags & TrieFormat.flagException) != 0
        let hasWildcard = (flags & TrieFormat.flagWildcard) != 0
        let childCount = Int(UInt16(np[1]) | (UInt16(np[2]) << 8))

        var cursor = 3
        var wildcardOffset: UInt32 = 0
        if hasWildcard {
            wildcardOffset = UInt32(np[cursor])
                           | (UInt32(np[cursor + 1]) << 8)
                           | (UInt32(np[cursor + 2]) << 16)
                           | (UInt32(np[cursor + 3]) << 24)
            cursor += 4
        }
        let childrenStart = np + cursor

        var best: (depth: Int, exception: Bool) = (0, false)
        if isTerminal && labelsConsumed > 0 {
            best = (labelsConsumed, isException)
        }

        guard labelsConsumed < labelCount else { return best }

        let labelIdx = labelCount - 1 - labelsConsumed
        let labelPtr = utf8 + labelStarts[labelIdx]
        let labelLen = labelEnds[labelIdx] - labelStarts[labelIdx]

        if let childOff = Self.findChild(childrenStart: childrenStart,
                                         count: childCount,
                                         labelPtr: labelPtr,
                                         labelLen: labelLen) {
            let r = walk(base: base, nodeOffset: childOff,
                         labelsConsumed: labelsConsumed + 1,
                         labelCount: labelCount,
                         labelStarts: labelStarts, labelEnds: labelEnds,
                         utf8: utf8)
            best = Self.better(best, r)
        }
        if hasWildcard {
            let r = walk(base: base, nodeOffset: wildcardOffset,
                         labelsConsumed: labelsConsumed + 1,
                         labelCount: labelCount,
                         labelStarts: labelStarts, labelEnds: labelEnds,
                         utf8: utf8)
            best = Self.better(best, r)
        }
        return best
    }

    @inline(__always)
    private static func better(_ a: (depth: Int, exception: Bool),
                               _ b: (depth: Int, exception: Bool)) -> (Int, Bool) {
        if a.depth == 0 { return b }
        if b.depth == 0 { return a }
        if a.exception != b.exception { return a.exception ? a : b }
        return a.depth >= b.depth ? a : b
    }

    @inline(__always)
    private static func findChild(childrenStart: UnsafePointer<UInt8>,
                                  count: Int,
                                  labelPtr: UnsafePointer<UInt8>,
                                  labelLen: Int) -> UInt32? {
        var cursor = 0
        for _ in 0..<count {
            let clen = Int(childrenStart[cursor])
            cursor += 1
            if clen == labelLen && memcmpEqual(childrenStart + cursor, labelPtr, clen) {
                let off = UInt32(childrenStart[cursor + clen])
                        | (UInt32(childrenStart[cursor + clen + 1]) << 8)
                        | (UInt32(childrenStart[cursor + clen + 2]) << 16)
                        | (UInt32(childrenStart[cursor + clen + 3]) << 24)
                return off
            }
            cursor += clen + 4
        }
        return nil
    }

    @inline(__always)
    private static func memcmpEqual(_ a: UnsafePointer<UInt8>,
                                    _ b: UnsafePointer<UInt8>,
                                    _ n: Int) -> Bool {
        var i = 0
        while i < n {
            if a[i] != b[i] { return false }
            i += 1
        }
        return true
    }
}
