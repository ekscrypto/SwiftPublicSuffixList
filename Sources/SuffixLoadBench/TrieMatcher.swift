import Foundation

/// Walks a serialized trie in-place. Holds the `Data` alive; per-call
/// `withUnsafeBytes` gives us a short-lived pointer into the mmapped pages.
final class TrieMatcher {

    private let data: Data
    private let rootOffset: UInt32

    init(data: Data) {
        self.data = data
        self.rootOffset = data.withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            precondition(p[0] == 0x50 && p[1] == 0x53 && p[2] == 0x4C && p[3] == 0x54,
                         "bad magic")
            precondition(p[4] == TrieFormat.version, "unsupported version")
            return UInt32(p[8])
                 | (UInt32(p[9]) << 8)
                 | (UInt32(p[10]) << 16)
                 | (UInt32(p[11]) << 24)
        }
    }

    /// Zero-allocation fast path. Returns nil when the candidate isn't a valid
    /// host, the current matcher returns nil in the same cases.
    func isUnrestricted(_ candidate: String) -> Bool {
        // Host-level validation mirroring PublicSuffixMatcher.isHost / isLabel.
        guard Self.isValidHost(candidate) else { return false }
        let utf8 = Array(candidate.utf8)

        // Split into label ranges, validate per-label length / hyphen rules.
        var labelStarts: [Int] = [0]
        var labelEnds: [Int] = []
        labelStarts.reserveCapacity(8)
        labelEnds.reserveCapacity(8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x2E { // '.'
                labelEnds.append(i)
                labelStarts.append(i + 1)
            }
            i += 1
        }
        labelEnds.append(utf8.count)
        let labelCount = labelStarts.count
        for idx in 0..<labelCount {
            let len = labelEnds[idx] - labelStarts[idx]
            if !(1...63).contains(len) { return false }
            if utf8[labelStarts[idx]] == 0x2D { return false }
            if utf8[labelEnds[idx] - 1] == 0x2D { return false }
        }

        // Walk.
        let result: (depth: Int, exception: Bool) = data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return utf8.withUnsafeBufferPointer { u in
                labelStarts.withUnsafeBufferPointer { ls in
                    labelEnds.withUnsafeBufferPointer { le in
                        walk(
                            base: base,
                            nodeOffset: rootOffset,
                            labelsConsumed: 0,
                            labelCount: labelCount,
                            labelStarts: ls.baseAddress!,
                            labelEnds: le.baseAddress!,
                            utf8: u.baseAddress!
                        )
                    }
                }
            }
        }
        if result.depth == 0 { return false } // no rule matched → isUnrestricted == false
        // isRestricted: not an exception, AND not longer than the prevailing rule.
        let isRestricted = !result.exception && (labelCount <= result.depth)
        return !isRestricted
    }

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
        // Match parity: any exception beats any non-exception.
        if a.exception != b.exception { return a.exception ? a : b }
        return a.depth >= b.depth ? a : b
    }

    /// Children are sorted by UTF-8 bytes; do a binary search.
    @inline(__always)
    private static func findChild(childrenStart: UnsafePointer<UInt8>,
                                  count: Int,
                                  labelPtr: UnsafePointer<UInt8>,
                                  labelLen: Int) -> UInt32? {
        // We don't know each child's byte offset without iterating (variable
        // length records), so a true binary search would require an index.
        // Linear scan is plenty fast for the child fan-outs we see in practice
        // (root ~1200, most nodes <10). If the root scan dominates we can add
        // a first-byte skip table later.
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

    // MARK: - Host validation (mirrors PublicSuffixMatcher.isHost)

    private static let disallowed: Set<UInt8> = {
        var s = Set<UInt8>()
        // ",~:!@#$%^&'\"(){}_*"
        for c in [UInt8](",~:!@#$%^&'\"(){}_*".utf8) { s.insert(c) }
        // whitespace + control: 0..31, 127, 32 space
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
}
