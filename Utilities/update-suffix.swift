//
//  update-suffix.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-01-22
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//
//  Standalone script: downloads the latest Public Suffix List from
//  publicsuffix.org and writes two artifacts to Sources/SwiftPublicSuffixList/:
//
//    registry.json   committed for CI diffing (used by the nightly workflow to
//                    summarize added/removed suffixes in the changelog).
//    registry.trie   the binary trie that's actually bundled at runtime.
//
//  The trie builder is inlined here so the script stays a single `swift run`
//  target with no module imports. It mirrors the implementation in
//  Sources/SwiftPublicSuffixList/TrieBuilder.swift — keep them in sync.
//

import Foundation

// MARK: - Punycode (RFC 3492)
//
// Inlined here so the update script can convert IDN labels to ACE form
// before building the trie. Keep in sync with
// Sources/SwiftPublicSuffixList/Punycode.swift — this is a byte-for-byte
// port of the same encoder.

enum Punycode {
    static let base: UInt32 = 36
    static let tmin: UInt32 = 1
    static let tmax: UInt32 = 26
    static let skew: UInt32 = 38
    static let damp: UInt32 = 700
    static let initialBias: UInt32 = 72
    static let initialN: UInt32 = 0x80

    static func toACE(_ label: String) -> String {
        var hasNonASCII = false
        for scalar in label.unicodeScalars where scalar.value >= 0x80 {
            hasNonASCII = true
            break
        }
        if !hasNonASCII { return label }
        let scalars = label.unicodeScalars.map { $0.value }
        return "xn--" + encode(scalars)
    }

    static func adapt(delta: UInt32, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var d = firstTime ? (delta / damp) : (delta / 2)
        d = d + (d / numPoints)
        var k: UInt32 = 0
        while d > ((base - tmin) * tmax) / 2 {
            d = d / (base - tmin)
            k = k + base
        }
        return k + (((base - tmin + 1) * d) / (d + skew))
    }

    static func digit(_ d: UInt32) -> UInt8 {
        if d < 26 { return UInt8(0x61 + d) }
        return UInt8(0x30 + d - 26)
    }

    static func encode(_ input: [UInt32]) -> String {
        var n: UInt32 = initialN
        var delta: UInt32 = 0
        var bias: UInt32 = initialBias
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)

        var h: UInt32 = 0
        var b: UInt32 = 0
        for cp in input where cp < 0x80 {
            output.append(UInt8(cp))
            h += 1
            b += 1
        }
        if b > 0 {
            output.append(0x2D)
        }

        let total = UInt32(input.count)
        while h < total {
            var m: UInt32 = .max
            for cp in input where cp >= n && cp < m {
                m = cp
            }
            delta = delta + (m - n) * (h + 1)
            n = m
            for cp in input {
                if cp < n { delta += 1 }
                if cp == n {
                    var q = delta
                    var k = base
                    while true {
                        let t: UInt32
                        if k <= bias + tmin { t = tmin }
                        else if k >= bias + tmax { t = tmax }
                        else { t = k - bias }
                        if q < t { break }
                        output.append(digit(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, numPoints: h + 1, firstTime: h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(bytes: output, encoding: .ascii)!
    }
}

// MARK: - Fetch

let publicSuffixUrl = URL(string: "https://publicsuffix.org/list/public_suffix_list.dat")!
guard let publicSuffixData = try? Data(contentsOf: publicSuffixUrl),
      let publicSuffixAsString = String(data: publicSuffixData, encoding: .utf8)
else {
    print("Failed to download and decode public_suffix_list.dat")
    exit(-1)
}

let rules: [[String]] = publicSuffixAsString
    .components(separatedBy: .newlines)
    .filter({ !$0.hasPrefix("//") && !$0.isEmpty })
    .map({ $0.components(separatedBy: ".") })

// MARK: - JSON (kept for CI diffing)

guard let jsonData = try? JSONEncoder().encode(rules) else {
    fatalError("Unable to encode rules as JSON")
}

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")
    .appendingPathComponent("SwiftPublicSuffixList")

let jsonUrl = outputDir.appendingPathComponent("registry.json")
do {
    try jsonData.write(to: jsonUrl)
    print("Wrote \(jsonUrl.path) (\(jsonData.count) bytes)")
} catch {
    print("Failed to write registry.json: \(error)")
    exit(-2)
}

// MARK: - Trie

// Mirrors Sources/SwiftPublicSuffixList/TrieFormat.swift. Keep the version
// byte and layout in sync with the library; see that file for the canonical
// format description.
let trieMagic: [UInt8] = [0x50, 0x53, 0x4C, 0x54] // "PSLT"
let trieVersion: UInt8 = 2
let trieHeaderSize = 24
let trieTrailerSize = 4  // trailing CRC32
let flagTerminal: UInt8  = 0x01
let flagException: UInt8 = 0x02
let flagWildcard: UInt8  = 0x04
let nodeSentinel: UInt8  = 0xE9

// CRC32 (zlib-compatible).
let crcTable: [UInt32] = {
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

func crc32(_ data: Data, count: Int) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    data.withUnsafeBytes { raw in
        let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(p[i])) & 0xFF)]
        }
    }
    return crc ^ 0xFFFFFFFF
}

final class BuildTrieNode {
    var isTerminal = false
    var isException = false
    var wildcardChild: BuildTrieNode?
    var children: [String: BuildTrieNode] = [:]
}

func buildTrie(rules: [[String]]) -> BuildTrieNode {
    let root = BuildTrieNode()
    for rule in rules {
        guard !rule.isEmpty else { continue }
        var node = root
        var isExceptionRule = false
        for i in stride(from: rule.count - 1, through: 0, by: -1) {
            let raw = rule[i]
            if raw.isEmpty { continue }
            if i == 0 && raw.hasPrefix("!") {
                isExceptionRule = true
                let clean = Punycode.toACE(String(raw.dropFirst()))
                node = node.children[clean] ?? {
                    let n = BuildTrieNode(); node.children[clean] = n; return n
                }()
            } else if raw == "*" {
                if let w = node.wildcardChild { node = w }
                else {
                    let n = BuildTrieNode(); node.wildcardChild = n; node = n
                }
            } else {
                let ace = Punycode.toACE(raw)
                node = node.children[ace] ?? {
                    let n = BuildTrieNode(); node.children[ace] = n; return n
                }()
            }
        }
        node.isTerminal = true
        if isExceptionRule { node.isException = true }
    }
    return root
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}

func nodeCount(_ node: BuildTrieNode) -> Int {
    var n = 1
    if let wc = node.wildcardChild { n += nodeCount(wc) }
    for (_, c) in node.children { n += nodeCount(c) }
    return n
}

@discardableResult
func writeNode(_ node: BuildTrieNode, into out: inout Data) -> UInt32 {
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
    if node.isTerminal { flags |= flagTerminal }
    if node.isException { flags |= flagException }
    if node.wildcardChild != nil { flags |= flagWildcard }
    out.append(nodeSentinel)
    out.append(flags)
    out.appendLE(UInt16(sorted.count))
    if node.wildcardChild != nil {
        out.appendLE(wildcardOffset)
    }
    for (i, (label, _)) in sorted.enumerated() {
        let utf8 = Array(label.utf8)
        precondition(utf8.count <= 63,
                     "label longer than 63 bytes (DNS max): \(label)")
        out.append(UInt8(utf8.count))
        out.append(contentsOf: utf8)
        out.appendLE(childOffsets[i])
    }
    return myOffset
}

func serializeTrie(root: BuildTrieNode, ruleCount: Int) -> Data {
    var out = Data()
    out.append(contentsOf: Array(repeating: UInt8(0), count: trieHeaderSize))
    let rootOffset = writeNode(root, into: &out)
    let nodes = nodeCount(root)
    out.append(contentsOf: [UInt8](repeating: 0, count: trieTrailerSize))
    let byteCount = UInt32(out.count)

    var header = Data()
    header.append(contentsOf: trieMagic)
    header.append(trieVersion)
    header.append(0)
    header.appendLE(UInt16(0))
    header.appendLE(rootOffset)
    header.appendLE(UInt32(nodes))
    header.appendLE(UInt32(ruleCount))
    header.appendLE(byteCount)
    precondition(header.count == trieHeaderSize)
    out.replaceSubrange(0..<trieHeaderSize, with: header)

    let crcRange = Int(byteCount) - trieTrailerSize
    let crc = crc32(out, count: crcRange)
    var crcLE = crc.littleEndian
    Swift.withUnsafeBytes(of: &crcLE) { bytes in
        out.replaceSubrange(crcRange..<crcRange + trieTrailerSize, with: bytes)
    }
    return out
}

let trieRoot = buildTrie(rules: rules)
let trieData = serializeTrie(root: trieRoot, ruleCount: rules.count)
let trieUrl = outputDir.appendingPathComponent("registry.trie")
do {
    try trieData.write(to: trieUrl)
    print("Wrote \(trieUrl.path) (\(trieData.count) bytes, \(nodeCount(trieRoot)) nodes)")
} catch {
    print("Failed to write registry.trie: \(error)")
    exit(-3)
}
