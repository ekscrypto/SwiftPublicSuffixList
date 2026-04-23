//
//  TrieFormat.swift
//  SwiftPublicSuffixList
//
//  Binary trie format used for the embedded Public Suffix List resource
//  and any trie produced by `TrieBuilder.buildAndSerialize(rules:)`.
//
//  Layout (little-endian throughout):
//
//  Header (24 bytes):
//    magic        4  'P','S','L','T'
//    version      1  current format version
//    flags        1  reserved
//    _padding     2  reserved
//    rootOffset   4  absolute offset into buffer of the root node
//    nodeCount    4  diagnostic
//    ruleCount    4  diagnostic
//    byteCount    4  total buffer size, includes header + body + trailer
//
//  Body: node records starting at offset 24.
//
//  Trailer (4 bytes, last 4 bytes of buffer):
//    crc32        4  zlib-compatible CRC32 over bytes[0 ..< byteCount - 4]
//
//  Node:
//    sentinel     1  0xE9 — cheap runtime "did we land on a real node?" check
//    flags        1
//      bit 0  isTerminal      (path from root == public-suffix rule)
//      bit 1  isException     (terminal inverts isRestricted)
//      bit 2  hasWildcard
//      bits 3-7 reserved; must be zero
//    childCount   2
//    if hasWildcard: wildcardOffset 4
//    children[childCount], sorted by label UTF-8 lex order:
//        labelLen    1  (> 0)
//        labelBytes  labelLen bytes
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
    static let version: UInt8 = 2
    static let headerSize = 24
    static let trailerSize = 4  // trailing CRC32

    static let flagTerminal: UInt8 = 0x01
    static let flagException: UInt8 = 0x02
    static let flagWildcard: UInt8 = 0x04
    static let reservedFlagMask: UInt8 = 0xF8  // bits that must be zero in a valid node

    /// Every node starts with this byte. Cheap runtime check that pointer
    /// arithmetic landed on a real node boundary — even if validation has
    /// proven the structure at load time, runtime reads still assert it as
    /// defense-in-depth against post-load memory corruption.
    static let nodeSentinel: UInt8 = 0xE9
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

// MARK: - CRC32 (zlib-compatible, table-driven)

enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Computes CRC32 over the first `count` bytes of `data`.
    static func checksum(of data: Data, count: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return checksum(UnsafeBufferPointer(start: p, count: count))
        }
    }
}
