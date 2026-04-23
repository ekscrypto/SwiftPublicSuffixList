//
//  TrieBuilder.swift
//  SwiftPublicSuffixList
//
//  Builds an in-memory trie from a list of PSL rules (`[[String]]`) and
//  serializes it into the binary format described in `TrieFormat.swift`.
//
//  The resulting `Data` can be written to disk and later memory-mapped by
//  `TrieMatcher` for zero-copy matching.
//

import Foundation

final class BuildTrieNode {
    var isTerminal: Bool = false
    var isException: Bool = false
    var wildcardChild: BuildTrieNode?
    var children: [String: BuildTrieNode] = [:]
    var serializedOffset: UInt32 = 0
}

/// Builds and serializes a trie representation of a public suffix rule set.
///
/// Used by the nightly update tooling to produce the embedded `registry.trie`
/// resource, and by `PublicSuffixList` at runtime when the caller supplies a
/// custom `[[String]]` rule set via `PublicSuffixList(source: .rules(...))`.
///
/// It's also the extension point for applications that want to ship their own
/// pre-compiled trie — fetch an updated rule set from your CDN, build a trie
/// on the fly, and cache the bytes for the next launch:
///
/// ```swift
/// let rules: [[String]] = // decoded from wherever you source them
/// let bytes: Data = TrieBuilder.buildAndSerialize(rules: rules)
/// try bytes.write(to: cacheUrl)
///
/// // Later …
/// let list = PublicSuffixList(source: .filePath(cacheUrl.path))
/// ```
public enum TrieBuilder {

    /// Builds a trie from the supplied rules and returns the serialized bytes.
    ///
    /// Rules must be in leftmost-first order (the same order publicsuffix.org
    /// distributes them in — `com.ac` becomes `["com", "ac"]`). `*` as the
    /// leftmost label is a wildcard; a `!` prefix on the leftmost label
    /// marks the rule as an exception.
    ///
    /// ```swift
    /// let bytes = TrieBuilder.buildAndSerialize(rules: [
    ///     ["com"],
    ///     ["co", "uk"],
    ///     ["*", "ck"],
    ///     ["!www", "ck"],
    /// ])
    /// try bytes.write(to: URL(fileURLWithPath: "registry.trie"))
    /// ```
    ///
    /// - Parameter rules: Array of rules, each an array of labels.
    /// - Returns: Serialized trie bytes. The resulting blob is the same
    ///   format consumed by `PublicSuffixList(source: .filePath(...))` and
    ///   produced by `PublicSuffixList.export(to:)`.
    public static func buildAndSerialize(rules: [[String]]) -> Data {
        let root = build(rules: rules)
        return serialize(root: root, ruleCount: rules.count)
    }

    static func build(rules: [[String]]) -> BuildTrieNode {
        let root = BuildTrieNode()
        for rule in rules {
            guard !rule.isEmpty else { continue }
            var node = root
            var isExceptionRule = false
            // Walk TLD (rule[last]) → leftmost (rule[0]).
            for i in stride(from: rule.count - 1, through: 0, by: -1) {
                let raw = rule[i]
                if raw.isEmpty {
                    // Skip empty labels (e.g., from stray dots). The legacy
                    // matcher discarded these by virtue of length checks.
                    continue
                }
                if i == 0 && raw.hasPrefix("!") {
                    isExceptionRule = true
                    let clean = String(raw.dropFirst())
                    if let existing = node.children[clean] {
                        node = existing
                    } else {
                        let n = BuildTrieNode()
                        node.children[clean] = n
                        node = n
                    }
                } else if raw == "*" {
                    if let w = node.wildcardChild {
                        node = w
                    } else {
                        let n = BuildTrieNode()
                        node.wildcardChild = n
                        node = n
                    }
                } else {
                    if let existing = node.children[raw] {
                        node = existing
                    } else {
                        let n = BuildTrieNode()
                        node.children[raw] = n
                        node = n
                    }
                }
            }
            node.isTerminal = true
            if isExceptionRule {
                node.isException = true
            }
        }
        return root
    }

    static func serialize(root: BuildTrieNode, ruleCount: Int) -> Data {
        var out = Data()
        out.append(contentsOf: Array(repeating: UInt8(0), count: TrieFormat.headerSize))
        let rootOffset = writeNode(root, into: &out)
        let nodes = nodeCount(root)
        let byteCount = UInt32(out.count)
        var header = Data()
        header.append(contentsOf: TrieFormat.magic)
        header.append(TrieFormat.version)
        header.append(0) // flags
        header._pslAppendLE(UInt16(0)) // padding
        header._pslAppendLE(rootOffset)
        header._pslAppendLE(UInt32(nodes))
        header._pslAppendLE(UInt32(ruleCount))
        header._pslAppendLE(byteCount)
        precondition(header.count == TrieFormat.headerSize)
        out.replaceSubrange(0..<TrieFormat.headerSize, with: header)
        return out
    }

    private static func nodeCount(_ node: BuildTrieNode) -> Int {
        var n = 1
        if let wc = node.wildcardChild { n += nodeCount(wc) }
        for (_, c) in node.children { n += nodeCount(c) }
        return n
    }

    @discardableResult
    private static func writeNode(_ node: BuildTrieNode, into out: inout Data) -> UInt32 {
        var wildcardOffset: UInt32 = 0
        if let wc = node.wildcardChild {
            wildcardOffset = writeNode(wc, into: &out)
        }
        let sorted = node.children.sorted { lhs, rhs in
            let a = Array(lhs.key.utf8)
            let b = Array(rhs.key.utf8)
            return a.lexicographicallyPrecedes(b)
        }
        var childOffsets: [UInt32] = []
        childOffsets.reserveCapacity(sorted.count)
        for (_, child) in sorted {
            childOffsets.append(writeNode(child, into: &out))
        }

        let myOffset = UInt32(out.count)
        var flags: UInt8 = 0
        if node.isTerminal { flags |= TrieFormat.flagTerminal }
        if node.isException { flags |= TrieFormat.flagException }
        if node.wildcardChild != nil { flags |= TrieFormat.flagWildcard }
        out.append(flags)
        out._pslAppendLE(UInt16(sorted.count))
        if node.wildcardChild != nil {
            out._pslAppendLE(wildcardOffset)
        }
        for (i, (label, _)) in sorted.enumerated() {
            let utf8 = Array(label.utf8)
            precondition(utf8.count <= 255, "label longer than 255 bytes: \(label)")
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
            out._pslAppendLE(childOffsets[i])
        }
        node.serializedOffset = myOffset
        return myOffset
    }
}
