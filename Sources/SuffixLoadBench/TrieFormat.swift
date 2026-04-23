import Foundation

// Binary trie format — memory-mapped, walked in place.
//
// Header (24 bytes, little-endian):
//   magic        4  'P','S','L','T'
//   version      1  == 1
//   flags        1  reserved
//   _padding     2
//   rootOffset   4  absolute offset into buffer of the root node
//   nodeCount    4  diagnostic
//   ruleCount    4  diagnostic
//   byteCount    4  diagnostic (total buffer size)
//
// Node:
//   flags        1
//     bit 0  isTerminal      (path from root == public-suffix rule)
//     bit 1  isException     (terminal inverts isRestricted; only meaningful with bit 0)
//     bit 2  hasWildcard
//   childCount   2
//   if hasWildcard: wildcardOffset 4
//   children[childCount], sorted by label UTF-8 lex order:
//       labelLen 1
//       labelBytes labelLen
//       childOffset 4
//
// Rule storage in [[String]] is right-to-left (TLD at rule[last]).
// The trie is built right-to-left: root → TLD → second-level → …
// `!` prefix on rule[0] becomes the terminal's `isException` flag with the `!`
// stripped from the label bytes. `*` becomes a wildcard child.

enum TrieFormat {
    static let magic: [UInt8] = [0x50, 0x53, 0x4C, 0x54] // "PSLT"
    static let version: UInt8 = 1
    static let headerSize = 24

    static let flagTerminal: UInt8 = 0x01
    static let flagException: UInt8 = 0x02
    static let flagWildcard: UInt8 = 0x04
}

final class BuildTrieNode {
    var isTerminal: Bool = false
    var isException: Bool = false
    var wildcardChild: BuildTrieNode?
    var children: [String: BuildTrieNode] = [:]
    var serializedOffset: UInt32 = 0
}

enum TrieBuilder {

    static func build(rules: [[String]]) -> BuildTrieNode {
        let root = BuildTrieNode()
        for rule in rules {
            guard !rule.isEmpty else { continue }
            var node = root
            var isExceptionRule = false
            // Walk TLD (rule[last]) → leftmost (rule[0]).
            for i in stride(from: rule.count - 1, through: 0, by: -1) {
                let raw = rule[i]
                if i == 0 && raw.hasPrefix("!") {
                    isExceptionRule = true
                    let clean = String(raw.dropFirst())
                    node = node.children[clean] ?? {
                        let n = BuildTrieNode()
                        node.children[clean] = n
                        return n
                    }()
                } else if raw == "*" {
                    if let w = node.wildcardChild {
                        node = w
                    } else {
                        let n = BuildTrieNode()
                        node.wildcardChild = n
                        node = n
                    }
                } else {
                    node = node.children[raw] ?? {
                        let n = BuildTrieNode()
                        node.children[raw] = n
                        return n
                    }()
                }
            }
            node.isTerminal = true
            if isExceptionRule {
                node.isException = true
            }
        }
        return root
    }

    static func nodeCount(_ root: BuildTrieNode) -> Int {
        var n = 1
        if let wc = root.wildcardChild { n += nodeCount(wc) }
        for (_, c) in root.children { n += nodeCount(c) }
        return n
    }
}

enum TrieSerializer {

    /// Serializes the trie into a flat Data buffer.
    static func serialize(root: BuildTrieNode, ruleCount: Int) -> Data {
        var out = Data()
        // Reserve header.
        out.append(contentsOf: Array(repeating: UInt8(0), count: TrieFormat.headerSize))
        // Post-order body.
        let rootOffset = writeNode(root, into: &out)
        let nodeCount = TrieBuilder.nodeCount(root)
        let byteCount = UInt32(out.count)
        // Back-patch header.
        var header = Data()
        header.append(contentsOf: TrieFormat.magic)
        header.append(TrieFormat.version)
        header.append(0) // flags
        header.appendLE(UInt16(0)) // padding
        header.appendLE(rootOffset)
        header.appendLE(UInt32(nodeCount))
        header.appendLE(UInt32(ruleCount))
        header.appendLE(byteCount)
        precondition(header.count == TrieFormat.headerSize)
        out.replaceSubrange(0..<TrieFormat.headerSize, with: header)
        return out
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
        out.appendLE(UInt16(sorted.count))
        if node.wildcardChild != nil {
            out.appendLE(wildcardOffset)
        }
        for (i, (label, _)) in sorted.enumerated() {
            let utf8 = Array(label.utf8)
            precondition(utf8.count <= 255)
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
            out.appendLE(childOffsets[i])
        }
        node.serializedOffset = myOffset
        return myOffset
    }
}
