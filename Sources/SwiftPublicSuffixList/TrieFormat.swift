//
//  TrieFormat.swift
//  SwiftPublicSuffixList
//
//  Binary trie format used for the embedded Public Suffix List resource.
//
//  Header (24 bytes, little-endian):
//    magic        4  'P','S','L','T'
//    version      1  == 1
//    flags        1  reserved
//    _padding     2
//    rootOffset   4  absolute offset into buffer of the root node
//    nodeCount    4  diagnostic
//    ruleCount    4  diagnostic
//    byteCount    4  diagnostic (total buffer size)
//
//  Node:
//    flags        1
//      bit 0  isTerminal      (path from root == public-suffix rule)
//      bit 1  isException     (terminal inverts isRestricted; only meaningful with bit 0)
//      bit 2  hasWildcard
//    childCount   2
//    if hasWildcard: wildcardOffset 4
//    children[childCount], sorted by label UTF-8 lex order:
//        labelLen 1
//        labelBytes labelLen
//        childOffset 4
//
//  Rule storage in [[String]] is right-to-left (TLD at rule[last]).
//  The trie is built right-to-left: root → TLD → second-level → …
//  `!` prefix on rule[0] becomes the terminal's `isException` flag with the `!`
//  stripped from the label bytes. `*` becomes a wildcard child.
//

import Foundation

enum TrieFormat {
    static let magic: [UInt8] = [0x50, 0x53, 0x4C, 0x54] // "PSLT"
    static let version: UInt8 = 1
    static let headerSize = 24

    static let flagTerminal: UInt8 = 0x01
    static let flagException: UInt8 = 0x02
    static let flagWildcard: UInt8 = 0x04
}

extension Data {
    mutating func _pslAppendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func _pslAppendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
