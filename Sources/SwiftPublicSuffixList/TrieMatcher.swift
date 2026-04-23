//
//  TrieMatcher.swift
//  SwiftPublicSuffixList
//
//  Walks a serialized trie in-place. Holds the backing `Data` alive; each
//  match does a short `withUnsafeBytes` to get a pointer into the mmapped
//  pages, so we never copy the buffer.
//
//  Untrusted buffers must go through `TrieMatcher.loadValidated(data:)`
//  which performs a full structural + CRC check before constructing the
//  matcher. The match-time walker additionally bounds-checks every read
//  and verifies per-node sentinels as defense-in-depth; a corrupted buffer
//  manifests as a "no match" result rather than an out-of-bounds read.
//

import Foundation

/// Result of matching a domain against a Public Suffix List.
///
/// Returned by ``PublicSuffixList/match(_:)-6q0fd`` (and its overloads), as
/// well as directly by `TrieMatcher.match(_:)`.
///
/// ```swift
/// if let m = PublicSuffixList.match("bbc.co.uk") {
///     m.prevailingRule   // ["co", "uk"]
///     m.isRestricted     // false — bbc.co.uk is registrable
/// }
///
/// if let m = PublicSuffixList.match("www.ck") {
///     m.prevailingRule   // ["!www", "ck"] — exception rule
///     m.isRestricted     // false — the exception overrides *.ck
/// }
/// ```
///
/// The legacy `matchedRules: [[String]]` field was removed in v2; it was
/// never part of the PSL algorithm and its construction dominated match
/// time.
public struct PublicSuffixMatch {
    /// The rule that determined the outcome, in the same leftmost-first
    /// order used when rules are supplied to ``PublicSuffixList``. Exception
    /// rules include the leading `!` on the leftmost label.
    public let prevailingRule: [String]

    /// `true` when the candidate *is* a public suffix (and therefore should
    /// not be treated as a registrable domain, e.g. should not be allowed to
    /// set cookies or host a site).
    public let isRestricted: Bool
}

/// Reasons a trie buffer was rejected during load-time validation.
enum TrieValidationError: Error, CustomStringConvertible {
    case bufferTooSmall(Int)
    case badMagic
    case unsupportedVersion(UInt8)
    case byteCountMismatch(declared: Int, actual: Int)
    case crcMismatch(declared: UInt32, computed: UInt32)
    case rootOffsetOutOfRange(UInt32)
    case nodeOffsetOutOfRange(UInt32)
    case nodeMissingSentinel(at: UInt32)
    case nodeReservedFlagsNotZero(at: UInt32, flags: UInt8)
    case childRecordOutOfRange(at: UInt32)
    case zeroLengthLabel(at: UInt32)
    case labelTooLong(at: UInt32, length: Int)
    case nonLDHLabelByte(at: UInt32, byte: UInt8)
    case cycleDetected(at: UInt32)

    var description: String {
        switch self {
        case .bufferTooSmall(let n):           return "buffer too small (\(n) bytes)"
        case .badMagic:                        return "not a PSLT trie (bad magic)"
        case .unsupportedVersion(let v):       return "unsupported trie version \(v)"
        case .byteCountMismatch(let d, let a): return "byteCount \(d) does not match buffer length \(a)"
        case .crcMismatch(let d, let c):       return "CRC32 mismatch: file says \(String(d, radix: 16)), computed \(String(c, radix: 16))"
        case .rootOffsetOutOfRange(let o):     return "rootOffset \(o) is out of range"
        case .nodeOffsetOutOfRange(let o):     return "node offset \(o) is out of range"
        case .nodeMissingSentinel(let o):      return "node at \(o) is missing the sentinel byte"
        case .nodeReservedFlagsNotZero(let o, let f):
            return "node at \(o) has reserved flag bits set: \(String(f, radix: 16))"
        case .childRecordOutOfRange(let o):    return "child record at node \(o) extends past buffer end"
        case .zeroLengthLabel(let o):          return "node at \(o) has a zero-length child label"
        case .labelTooLong(let o, let n):      return "node at \(o) has a child label of \(n) bytes (max 63)"
        case .nonLDHLabelByte(let o, let b):   return "node at \(o) has a non-LDH label byte 0x\(String(b, radix: 16))"
        case .cycleDetected(let o):            return "cycle detected at node \(o)"
        }
    }
}

final class TrieMatcher {

    let data: Data
    let rootOffset: UInt32
    let ruleCount: UInt32

    /// Internal designated initializer — trusts the buffer. Use only with
    /// bytes we produced ourselves (`TrieBuilder.buildAndSerialize`) or the
    /// embedded resource we ship in the package.
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

    /// Validating factory for untrusted bytes. Walks the whole trie once,
    /// verifying CRC, bounds, sentinels, and cycle-freeness. Returns nil
    /// (and logs) on any failure.
    static func loadValidated(data: Data,
                              logger: (String) -> Void = { _ in }) -> TrieMatcher? {
        do {
            try validate(data)
            return TrieMatcher(data: data)
        } catch let err as TrieValidationError {
            logger("TrieMatcher: rejecting buffer — \(err.description)")
            return nil
        } catch {
            logger("TrieMatcher: rejecting buffer — \(error)")
            return nil
        }
    }

    // MARK: - Validation

    static func validate(_ data: Data) throws {
        let total = data.count
        guard total >= TrieFormat.headerSize + TrieFormat.trailerSize else {
            throw TrieValidationError.bufferTooSmall(total)
        }

        try data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let end = p + total

            // Header fields.
            guard p[0] == 0x50 && p[1] == 0x53 && p[2] == 0x4C && p[3] == 0x54 else {
                throw TrieValidationError.badMagic
            }
            guard p[4] == TrieFormat.version else {
                throw TrieValidationError.unsupportedVersion(p[4])
            }
            let rootOff = readU32LE(p + 8)
            let byteCount = Int(readU32LE(p + 20))
            guard byteCount == total else {
                throw TrieValidationError.byteCountMismatch(declared: byteCount, actual: total)
            }

            // CRC.
            let crcOffset = total - TrieFormat.trailerSize
            let declaredCRC = readU32LE(p + crcOffset)
            let computedCRC = CRC32.checksum(UnsafeBufferPointer(start: p, count: crcOffset))
            guard declaredCRC == computedCRC else {
                throw TrieValidationError.crcMismatch(declared: declaredCRC, computed: computedCRC)
            }

            // Root offset must land in the body region.
            let bodyStart = TrieFormat.headerSize
            let bodyEnd = crcOffset
            guard Int(rootOff) >= bodyStart, Int(rootOff) < bodyEnd else {
                throw TrieValidationError.rootOffsetOutOfRange(rootOff)
            }

            // Walk every reachable node once. Detect cycles via a visited set.
            var visited = Set<UInt32>()
            try walkForValidation(
                base: p, end: end,
                nodeOffset: rootOff,
                bodyStart: bodyStart,
                bodyEnd: bodyEnd,
                visited: &visited
            )
        }
    }

    private static func walkForValidation(
        base: UnsafePointer<UInt8>,
        end: UnsafePointer<UInt8>,
        nodeOffset: UInt32,
        bodyStart: Int,
        bodyEnd: Int,
        visited: inout Set<UInt32>
    ) throws {
        let off = Int(nodeOffset)
        guard off >= bodyStart, off < bodyEnd else {
            throw TrieValidationError.nodeOffsetOutOfRange(nodeOffset)
        }
        if !visited.insert(nodeOffset).inserted {
            throw TrieValidationError.cycleDetected(at: nodeOffset)
        }

        let np = base + off
        // Minimum node size without wildcard and with zero children = 4 bytes
        // (sentinel + flags + childCount).
        guard np + 4 <= base + bodyEnd else {
            throw TrieValidationError.nodeOffsetOutOfRange(nodeOffset)
        }
        guard np[0] == TrieFormat.nodeSentinel else {
            throw TrieValidationError.nodeMissingSentinel(at: nodeOffset)
        }
        let flags = np[1]
        guard (flags & TrieFormat.reservedFlagMask) == 0 else {
            throw TrieValidationError.nodeReservedFlagsNotZero(at: nodeOffset, flags: flags)
        }
        let childCount = Int(UInt16(np[2]) | (UInt16(np[3]) << 8))
        let hasWildcard = (flags & TrieFormat.flagWildcard) != 0

        var cursor = 4
        var wildcardOffset: UInt32 = 0
        if hasWildcard {
            guard np + cursor + 4 <= base + bodyEnd else {
                throw TrieValidationError.childRecordOutOfRange(at: nodeOffset)
            }
            wildcardOffset = readU32LE(np + cursor)
            cursor += 4
        }

        // Children.
        var childOffsets: [UInt32] = []
        childOffsets.reserveCapacity(childCount)
        for _ in 0..<childCount {
            // Need labelLen byte.
            guard np + cursor + 1 <= base + bodyEnd else {
                throw TrieValidationError.childRecordOutOfRange(at: nodeOffset)
            }
            let labelLen = Int(np[cursor])
            guard labelLen > 0 else {
                throw TrieValidationError.zeroLengthLabel(at: nodeOffset)
            }
            // DNS labels are ≤ 63 bytes (RFC 1035). Reject anything larger —
            // the matcher clamps candidate labels to 63 so a longer stored
            // label can never match, and rejecting early prevents crafted
            // tries from stretching child records over arbitrary regions.
            guard labelLen <= 63 else {
                throw TrieValidationError.labelTooLong(at: nodeOffset, length: labelLen)
            }
            // Need labelLen + 4 more bytes (label + childOffset).
            guard np + cursor + 1 + labelLen + 4 <= base + bodyEnd else {
                throw TrieValidationError.childRecordOutOfRange(at: nodeOffset)
            }
            // Stored labels are ACE-form: ASCII LDH only (a-z, A-Z, 0-9, '-').
            // Reject anything else as malformed — the matcher caps candidate
            // labels to the same set, so a non-LDH stored byte can never match.
            for i in 0..<labelLen {
                let byte = np[cursor + 1 + i]
                let isLower = (byte >= 0x61 && byte <= 0x7A)
                let isUpper = (byte >= 0x41 && byte <= 0x5A)
                let isDigit = (byte >= 0x30 && byte <= 0x39)
                let isHyphen = (byte == 0x2D)
                guard isLower || isUpper || isDigit || isHyphen else {
                    throw TrieValidationError.nonLDHLabelByte(at: nodeOffset, byte: byte)
                }
            }
            let childOff = readU32LE(np + cursor + 1 + labelLen)
            childOffsets.append(childOff)
            cursor += 1 + labelLen + 4
        }

        // Recurse after reading this node fully (helps bound the visited set).
        if hasWildcard {
            try walkForValidation(base: base, end: end, nodeOffset: wildcardOffset,
                                  bodyStart: bodyStart, bodyEnd: bodyEnd, visited: &visited)
        }
        for off in childOffsets {
            try walkForValidation(base: base, end: end, nodeOffset: off,
                                  bodyStart: bodyStart, bodyEnd: bodyEnd, visited: &visited)
        }
    }

    @inline(__always)
    private static func readU32LE(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16) | (UInt32(p[3]) << 24)
    }

    // MARK: - Public matching

    func isUnrestricted(_ candidate: String) -> Bool {
        guard let ranges = validateAndSplit(candidate) else { return false }
        let utf8 = ranges.utf8Bytes
        let labelCount = ranges.labelCount
        let result: (depth: Int, exception: Bool) = data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let end = base + raw.count
            return utf8.withUnsafeBufferPointer { u in
                ranges.starts.withUnsafeBufferPointer { ls in
                    ranges.ends.withUnsafeBufferPointer { le in
                        walk(base: base, end: end,
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

    func match(_ candidate: String) -> PublicSuffixMatch? {
        guard let ranges = validateAndSplit(candidate) else { return nil }
        let utf8 = ranges.utf8Bytes
        let labelCount = ranges.labelCount
        let result: (depth: Int, exception: Bool) = data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let end = base + raw.count
            return utf8.withUnsafeBufferPointer { u in
                ranges.starts.withUnsafeBufferPointer { ls in
                    ranges.ends.withUnsafeBufferPointer { le in
                        walk(base: base, end: end,
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
            if utf8[starts[idx]] == 0x2D { return nil }
            if utf8[ends[idx] - 1] == 0x2D { return nil }
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
        for b in s.utf8 {
            // Reject non-ASCII. Callers must supply hostnames in ACE form
            // (`xn--…`); see the Punycode encoder. A Unicode hostname like
            // "example.香港" is silently rejected — pass "example.xn--j6w193g".
            if b >= 0x80 { return false }
            if disallowed.contains(b) { return false }
        }
        return true
    }

    // MARK: - Walker (bounds-checked + sentinel-checked)

    /// Walks the trie. Every read is bounds-checked against `end`, and every
    /// node reached is confirmed to start with the sentinel byte. Failure of
    /// either check short-circuits that path with `(depth: 0, exception: false)`
    /// — never an OOB read.
    private func walk(
        base: UnsafePointer<UInt8>,
        end: UnsafePointer<UInt8>,
        nodeOffset: UInt32,
        labelsConsumed: Int,
        labelCount: Int,
        labelStarts: UnsafePointer<Int>,
        labelEnds: UnsafePointer<Int>,
        utf8: UnsafePointer<UInt8>
    ) -> (depth: Int, exception: Bool) {
        let np = base + Int(nodeOffset)
        // Minimum node = sentinel + flags + childCount = 4 bytes.
        guard np >= base, np + 4 <= end else { return (0, false) }
        guard np[0] == TrieFormat.nodeSentinel else { return (0, false) }
        let flags = np[1]
        guard (flags & TrieFormat.reservedFlagMask) == 0 else { return (0, false) }
        let isTerminal = (flags & TrieFormat.flagTerminal) != 0
        let isException = (flags & TrieFormat.flagException) != 0
        let hasWildcard = (flags & TrieFormat.flagWildcard) != 0
        let childCount = Int(UInt16(np[2]) | (UInt16(np[3]) << 8))

        var cursor = 4
        var wildcardOffset: UInt32 = 0
        if hasWildcard {
            guard np + cursor + 4 <= end else { return (0, false) }
            wildcardOffset = UInt32(np[cursor])
                           | (UInt32(np[cursor + 1]) << 8)
                           | (UInt32(np[cursor + 2]) << 16)
                           | (UInt32(np[cursor + 3]) << 24)
            cursor += 4
        }
        let childrenStart = np + cursor
        let childrenEnd = end

        var best: (depth: Int, exception: Bool) = (0, false)
        if isTerminal && labelsConsumed > 0 {
            best = (labelsConsumed, isException)
        }

        guard labelsConsumed < labelCount else { return best }

        let labelIdx = labelCount - 1 - labelsConsumed
        let labelPtr = utf8 + labelStarts[labelIdx]
        let labelLen = labelEnds[labelIdx] - labelStarts[labelIdx]

        if let childOff = Self.findChild(childrenStart: childrenStart,
                                         childrenEnd: childrenEnd,
                                         count: childCount,
                                         labelPtr: labelPtr,
                                         labelLen: labelLen) {
            let r = walk(base: base, end: end, nodeOffset: childOff,
                         labelsConsumed: labelsConsumed + 1,
                         labelCount: labelCount,
                         labelStarts: labelStarts, labelEnds: labelEnds,
                         utf8: utf8)
            best = Self.better(best, r)
        }
        if hasWildcard {
            let r = walk(base: base, end: end, nodeOffset: wildcardOffset,
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
                                  childrenEnd: UnsafePointer<UInt8>,
                                  count: Int,
                                  labelPtr: UnsafePointer<UInt8>,
                                  labelLen: Int) -> UInt32? {
        var cursor = 0
        for _ in 0..<count {
            // Need at least labelLen byte.
            guard childrenStart + cursor + 1 <= childrenEnd else { return nil }
            let clen = Int(childrenStart[cursor])
            cursor += 1
            // Need clen label bytes + 4 offset bytes.
            guard childrenStart + cursor + clen + 4 <= childrenEnd else { return nil }
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
